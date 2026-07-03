module httpkube;

import core.time : Duration, MonoTime, seconds;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file : readText;
import vibe.data.json : Json, parseJsonString;
import std.string : strip;

import vibe.core.log : logInfo;
import vibe.http.client : HTTPClientRequest, HTTPClientResponse, HTTPClientSettings, requestHTTP;
import vibe.http.common : HTTPMethod, httpMethodString;
import vibe.stream.operations : readAllUTF8, readLine;
import vibe.stream.tls : TLSContext;

import metrics : recordApiCall, recordJobCreated, recordStatusPatch;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.station : Station;
import agentcore.kube.jobspec : agentContainerName;
import agentcore.kube.jsonbody : AgentListPage, parseAgentDefinition, parseAgentListPage, parseJobOutcome, parseStation;
import agentcore.kube.kubeclient : KubeClient, NotFound, PodResult;
import agentcore.kube.outputcap : capOutput;
import agentcore.reconcile.reconcile : JobOutcome;

import incluster : ClusterConfig;

enum crGroup = "agents.re-cinq.com";
enum crVersion = "v1alpha1";

/// Last lines requested from a pod's log: a coarse cap on what crosses the wire.
/// The byte-accurate tail kept in status.output is enforced by `capOutput`.
enum logTailLines = 10_000;

/// Page size for the namespace LIST: the API server returns at most this many
/// Agents per response and a `continue` token for the next page, so a large
/// namespace is fetched in bounded chunks rather than one unbounded GET.
enum listPageLimit = 500;

/// Thrown by `watchAgents` when the API server rejects the watch's starting
/// resourceVersion as too old (HTTP 410 Gone) — the change history it would need
/// to replay has been compacted away. The control loop catches it and does a full
/// paginated re-list to resync before watching again.
class WatchExpired : Exception
{
	this(string message) @safe pure nothrow
	{
		super(message);
	}
}

/// The fields of a `coordination.k8s.io/v1` Lease the election loop reads back:
/// who holds it, when they last renewed, the resourceVersion (used as an
/// optimistic-concurrency precondition on writes), and the takeover count.
/// `exists` is false when no Lease has been created yet (the GET 404s).
struct LeaseRecord
{
	bool exists;
	string holder;
	string renewTime;
	string resourceVersion;
	int transitions;
}

/// The Agent informer operations the reconcile loop needs on top of `KubeClient`: the
/// full paginated LIST and the long-lived watch stream. Behind an interface so the
/// watch/poll orchestration (leadership gating, resync, cache upkeep, concurrency
/// accounting) is fake-testable — the same seam posture as `KubeClient`/`LeaseClient`.
/// The real vibe-d implementation is `HttpKubeClient`.
interface AgentInformerClient : KubeClient
{
	/// List every Agent in the namespace (following `continue` tokens), with the list's
	/// `resourceVersion` for the watch to resume from.
	AgentListPage listAllAgents(string ns);

	/// Watch the Agent collection from `resourceVersion`, invoking `onLine` for each
	/// streamed line until the server closes the connection.
	void watchAgents(string ns, string resourceVersion, scope void delegate(string line) onLine);
}

/// The Lease operations the leader-election loop needs, behind an interface so the
/// loop is fake-testable — the same seam posture as `KubeClient`. The real vibe-d
/// implementation is `HttpKubeClient`.
interface LeaseClient
{
	/// Read the election Lease; `exists` is false when none has been created yet.
	LeaseRecord getLease(string ns, string name);

	/// Create the Lease. True when we created it (201); false when another replica
	/// created it first (409).
	bool createLease(string ns, Json body);

	/// Merge-patch the Lease (renew or takeover). True when the write landed (200);
	/// false when our resourceVersion was stale (409) — another replica wrote first.
	bool patchLease(string ns, string name, Json body);
}

/// `KubeClient` over the Kubernetes API server, spoken with vibe's HTTP client:
/// bearer-token auth, the cluster CA added to the TLS trust store, and
/// merge-patch for the status subresource. The long-lived watch stream
/// (`watchAgents`) is controller-only and sits beside the interface.
final class HttpKubeClient : KubeClient, LeaseClient, AgentInformerClient
{
	private ClusterConfig config;
	private HTTPClientSettings settings; /// normal requests: short read timeout
	private HTTPClientSettings watchSettings; /// the watch long poll: read timeout > server-side close
	private string cachedToken; /// last good bearer token; re-read from the SA token file each request

	this(ClusterConfig config)
	{
		this.config = config;
		this.cachedToken = config.token;
		this.settings = makeSettings(config.caFile, apiReadTimeout);
		this.watchSettings = makeSettings(config.caFile, watchReadTimeout);
	}

	/// Build client settings with connect + read timeouts and the in-cluster CA, so a
	/// stalled API server fails fast instead of blocking the fiber forever.
	private static HTTPClientSettings makeSettings(string ca, Duration readTimeout)
	{
		auto s = new HTTPClientSettings;
		s.connectTimeout = apiConnectTimeout;
		s.readTimeout = readTimeout;
		s.tlsContextSetup = (TLSContext ctx) @safe nothrow {
			try
				() @trusted { ctx.useTrustedCertificateFile(ca); }();
			catch (Exception)
			{
			}
		};
		return s;
	}

	override Station getStation(string ns, string name)
	{
		return parseStation(getJson(crUrl(ns, "stations", name), "Station " ~ name));
	}

	override AgentDefinition getAgentDefinition(string ns, string name)
	{
		return parseAgentDefinition(getJson(crUrl(ns, "agentdefinitions", name), "AgentDefinition " ~ name));
	}

	override void createJob(string ns, Json job)
	{
		if (send(HTTPMethod.POST, jobsUrl(ns), job, "application/json", [201, 409]) == 201)
			recordJobCreated();
	}

	override JobOutcome jobOutcome(string ns, string jobName)
	{
		return parseJobOutcome(getJson(jobUrl(ns, jobName), "Job " ~ jobName));
	}

	override void patchAgentStatus(string ns, string name, Json statusPatch)
	{
		const status = send(HTTPMethod.PATCH, crUrl(ns, "agents", name) ~ "/status", statusPatch,
			"application/merge-patch+json", [200, 409]);
		if (status == 409)
		{
			// The patch carried a resourceVersion precondition and the Agent changed
			// since we read it: drop this stale write. The next watch/poll reconcile
			// recomputes from fresh state — optimistic concurrency, no lost update.
			logInfo("status patch conflict for %s: superseded, will reconcile again", name);
			return;
		}
		recordStatusPatch();
	}

	/// List every Agent in the namespace, following `continue` tokens across pages
	/// so a large namespace arrives in bounded chunks. Returns the accumulated
	/// items with the list's `resourceVersion` — the point the watch resumes from.
	/// Controller-only (it sits beside `watchAgents`), not on the KubeClient seam.
	AgentListPage listAllAgents(string ns)
	{
		AgentListPage all;
		string continueToken;
		do
		{
			auto url = crCollectionUrl(ns, "agents") ~ "?limit=" ~ listPageLimit.to!string;
			if (continueToken.length)
				url ~= "&continue=" ~ continueToken;
			auto page = parseAgentListPage(getJson(url, "agents"));
			all.items ~= page.items;
			all.resourceVersion = page.resourceVersion;
			continueToken = page.continueToken;
		}
		while (continueToken.length);
		return all;
	}

	override void deleteAgent(string ns, string name, string resourceVersion = "")
	{
		Json body = Json.init;
		string contentType = "";
		if (resourceVersion.length)
		{
			Json preconditions = Json.emptyObject;
			preconditions["resourceVersion"] = Json(resourceVersion);
			body = Json.emptyObject;
			body["apiVersion"] = Json("meta.k8s.io/v1");
			body["kind"] = Json("DeleteOptions");
			body["preconditions"] = preconditions;
			contentType = "application/json";
		}
		// 409: the Agent changed since our cache snapshot — skip the delete rather than
		// remove a newer object. 404: already gone. Both are non-errors for pruning.
		send(HTTPMethod.DELETE, crUrl(ns, "agents", name), body, contentType, [200, 202, 404, 409]);
	}

	override string podNameForJob(string ns, string jobName)
	{
		auto list = getJson(podsUrl(ns) ~ "?labelSelector=job-name=" ~ jobName, "pods for " ~ jobName);
		if (list.type == Json.Type.object)
			if (auto items = "items" in list)
				if (items.type == Json.Type.array && items.get!(Json[]).length)
					return items.get!(Json[])[0]["metadata"]["name"].get!string;
		return "";
	}

	override PodResult podResult(string ns, string podName)
	{
		const code = agentExitCode(getJson(podUrl(ns, podName), "pod " ~ podName));
		const log = capOutput(getText(podLogUrl(ns, podName), "logs for " ~ podName),
			config.maxOutputBytes);
		return PodResult(code, log);
	}

	/// Stream Agent watch events (one newline-delimited JSON object per line) to
	/// `onLine` until the connection ends, resuming from `resourceVersion` (the
	/// last one observed; the controller seeds it from the list). A 410 Gone means
	/// that resourceVersion is too old to replay — surfaced as `WatchExpired` so
	/// the caller re-lists and resyncs rather than silently re-watching from a dead
	/// cursor. Any other non-200 (401 expired token, 403 RBAC regression, 5xx)
	/// throws: streaming its error body as "lines" would parse to zero events and
	/// look like a clean close, so the inform loop would reconnect every 2s forever
	/// with no log and no backoff while reconciliation silently degraded to the
	/// poll (#89). Throwing routes it to the loop's error path instead.
	void watchAgents(string ns, string resourceVersion, scope void delegate(string line) onLine)
	{
		const url = crCollectionUrl(ns, "agents") ~ watchQuery(resourceVersion, watchTimeoutSeconds);
		requestHTTP(url,
			(scope HTTPClientRequest req) { authorize(req); },
			(scope HTTPClientResponse res) {
				if (res.statusCode == 410)
				{
					res.dropBody();
					throw new WatchExpired("watch resourceVersion " ~ resourceVersion ~ " is too old (410 Gone)");
				}
				if (res.statusCode != 200)
				{
					res.dropBody();
					throw new Exception("watch agents: unexpected status " ~ res.statusCode.to!string);
				}
				while (!res.bodyReader.empty)
				{
					auto line = cast(string) res.bodyReader.readLine(size_t.max, "\n");
					if (line.length)
						onLine(line);
				}
			}, watchSettings);
	}

	/// Read the leader-election Lease. A 404 means none has been created yet,
	/// reported as `exists = false` rather than thrown — that is the signal to
	/// create one.
	override LeaseRecord getLease(string ns, string name)
	{
		int status;
		auto document = requestJson(leaseUrl(ns, name), status);
		if (status == 404)
			return LeaseRecord.init;
		enforce(status == 200, "Lease " ~ name ~ ": unexpected status " ~ status.to!string);
		return parseLeaseRecord(document);
	}

	/// Create the Lease. Returns true when we created it (201); a 409 means another
	/// replica created it first, so we did not win leadership.
	override bool createLease(string ns, Json body)
	{
		return send(HTTPMethod.POST, leasesUrl(ns), body, "application/json", [201, 409]) == 201;
	}

	/// Merge-patch the Lease (renew or takeover). Returns true when the write landed
	/// (200); a 409 means our resourceVersion was stale — another replica wrote
	/// first — so we did not hold or take leadership this tick.
	override bool patchLease(string ns, string name, Json body)
	{
		return send(HTTPMethod.PATCH, leaseUrl(ns, name), body, "application/merge-patch+json",
			[200, 409]) == 200;
	}

	/// GET a JSON document, returning the HTTP `status` and (on 200) the parsed
	/// body. The 404 policy is the caller's: `getJson` throws `NotFound`, while a
	/// Lease read treats it as "absent".
	private Json requestJson(string url, out int status)
	{
		Json document;
		int observed;
		timedRequest("GET", url,
			(scope HTTPClientRequest req) { authorize(req); },
			(scope HTTPClientResponse res) {
				observed = res.statusCode;
				const body = res.bodyReader.readAllUTF8();
				if (observed == 200)
					document = parseJsonString(body);
			});
		status = observed;
		return document;
	}

	private Json getJson(string url, string what)
	{
		int status;
		auto document = requestJson(url, status);
		enforce(status != 404, new NotFound(what ~ " not found"));
		enforce(status == 200, what ~ ": unexpected status " ~ status.to!string);
		return document;
	}

	private string getText(string url, string what)
	{
		string body;
		int status;
		timedRequest("GET", url,
			(scope HTTPClientRequest req) { authorize(req); },
			(scope HTTPClientResponse res) {
				status = res.statusCode;
				body = res.bodyReader.readAllUTF8();
			});
		enforce(status == 200, what ~ ": unexpected status " ~ status.to!string);
		return body;
	}

	/// The `agent` container's terminated exit code from a pod object, or 0 when it
	/// is not present (pod still running, or already GC'd).
	private int agentExitCode(Json pod)
	{
		if (pod.type != Json.Type.object)
			return 0;
		auto status = "status" in pod;
		if (status is null || status.type != Json.Type.object)
			return 0;
		auto containers = "containerStatuses" in *status;
		if (containers is null || containers.type != Json.Type.array)
			return 0;
		foreach (container; containers.get!(Json[]))
		{
			if (container.type != Json.Type.object)
				continue;
			auto name = "name" in container;
			if (name is null || name.get!string != agentContainerName)
				continue;
			auto state = "state" in container;
			if (state is null || state.type != Json.Type.object)
				continue;
			auto terminated = "terminated" in *state;
			if (terminated is null || terminated.type != Json.Type.object)
				continue;
			auto code = "exitCode" in *terminated;
			if (code !is null && code.type == Json.Type.int_)
				return cast(int) code.get!long;
		}
		return 0;
	}

	private int send(HTTPMethod method, string url, Json body, string contentType, int[] okCodes)
	{
		int status;
		timedRequest(httpMethodString(method), url,
			(scope HTTPClientRequest req) {
				req.method = method;
				authorize(req);
				if (body.type != Json.Type.undefined && body.type != Json.Type.null_)
					req.writeBody(cast(const(ubyte)[]) body.toString(), contentType);
			},
			(scope HTTPClientResponse res) { status = res.statusCode; res.dropBody(); });
		enforce(okCodes.canFind(status), url ~ ": unexpected status " ~ status.to!string);
		return status;
	}

	/// Issue one short request and record its wall-clock duration against the API
	/// latency summary, labelled by `verb`. The long-lived `watchAgents` stream is
	/// deliberately not routed here — it is not a request/response RPC.
	private void timedRequest(string verb, string url,
		scope void delegate(scope HTTPClientRequest) onRequest,
		scope void delegate(scope HTTPClientResponse) onResponse)
	{
		const start = MonoTime.currTime;
		requestHTTP(url, onRequest, onResponse, settings);
		recordApiCall(verb, (MonoTime.currTime - start).total!"nsecs" / 1e9);
	}

	private void authorize(scope HTTPClientRequest req)
	{
		cachedToken = refreshToken(config.tokenPath, cachedToken);
		if (cachedToken.length)
			req.headers["Authorization"] = "Bearer " ~ cachedToken;
	}

	private string crUrl(string ns, string plural, string name)
	{
		return crCollectionUrl(ns, plural) ~ "/" ~ name;
	}

	private string crCollectionUrl(string ns, string plural)
	{
		return config.apiBase ~ "/apis/" ~ crGroup ~ "/" ~ crVersion ~ "/namespaces/" ~ ns ~ "/" ~ plural;
	}

	private string jobsUrl(string ns)
	{
		return config.apiBase ~ "/apis/batch/v1/namespaces/" ~ ns ~ "/jobs";
	}

	private string jobUrl(string ns, string name)
	{
		return jobsUrl(ns) ~ "/" ~ name;
	}

	private string podsUrl(string ns)
	{
		return config.apiBase ~ "/api/v1/namespaces/" ~ ns ~ "/pods";
	}

	private string podUrl(string ns, string name)
	{
		return podsUrl(ns) ~ "/" ~ name;
	}

	private string podLogUrl(string ns, string name)
	{
		// Name the container explicitly: a Station template with a sidecar makes an
		// unqualified /log 400 ("a container name must be specified"), which would mark
		// every run in that Station output-unavailable.
		return podUrl(ns, name) ~ "/log?container=" ~ agentContainerName ~ "&tailLines="
			~ logTailLines.to!string;
	}

	private string leasesUrl(string ns)
	{
		return config.apiBase ~ "/apis/coordination.k8s.io/v1/namespaces/" ~ ns ~ "/leases";
	}

	private string leaseUrl(string ns, string name)
	{
		return leasesUrl(ns) ~ "/" ~ name;
	}
}

/// Read the leadership fields out of a Lease object. Missing fields fall back to
/// their zero value — a freshly created Lease may not carry every field yet.
LeaseRecord parseLeaseRecord(Json lease)
{
	LeaseRecord record;
	record.exists = true;
	record.resourceVersion = leaseField(lease, "metadata", "resourceVersion");
	record.holder = leaseField(lease, "spec", "holderIdentity");
	record.renewTime = leaseField(lease, "spec", "renewTime");
	record.transitions = cast(int) leaseTransitions(lease);
	return record;
}

private string leaseField(Json lease, string section, string key)
{
	auto value = leaseSection(lease, section, key);
	return (value !is null && value.type == Json.Type.string) ? value.get!string : "";
}

private long leaseTransitions(Json lease)
{
	auto value = leaseSection(lease, "spec", "leaseTransitions");
	return (value !is null && value.type == Json.Type.int_) ? value.get!long : 0;
}

private Json* leaseSection(Json lease, string section, string key)
{
	if (lease.type != Json.Type.object)
		return null;
	auto sec = section in lease;
	if (sec is null || sec.type != Json.Type.object)
		return null;
	return key in *sec;
}

/// Server-side watch timeout: the API server closes the long poll after this many
/// seconds, forcing the inform loop to reconnect (and resume from its last
/// resourceVersion). Without it a silently dropped connection leaves the watch fiber
/// blocked on a dead socket until OS TCP keepalive fires (hours).
enum watchTimeoutSeconds = 300;

/// Client timeouts. Normal requests fail fast if the API server stalls; the watch is
/// a long poll, so its read timeout sits above the server-side close (a real idle
/// watch stays open) but still breaks a half-open connection that never sends FIN.
enum apiConnectTimeout = 10.seconds;
enum apiReadTimeout = 30.seconds;
enum watchReadTimeout = (watchTimeoutSeconds + 60).seconds;

/// The watch query string: stream changes since `resourceVersion`, asking the server
/// to end the long poll after `timeoutSeconds`. Free + pure so it is unit-testable.
private string watchQuery(string resourceVersion, int timeoutSeconds)
{
	return "?watch=1&resourceVersion=" ~ resourceVersion ~ "&timeoutSeconds=" ~ timeoutSeconds.to!string;
}

/// The current bearer token, re-read from `path` so a rotated projected
/// service-account token is picked up — the kubelet swaps the file in place and the
/// token expires within ~1h, so a token read once at startup eventually 401s every
/// request. Falls back to `fallback` (the last good value) when no path is set
/// (out-of-cluster) or the file can't be read this instant (e.g. mid-rotation), so a
/// transient read never drops auth.
private string refreshToken(string path, string fallback)
{
	if (path.length == 0)
		return fallback;
	try
		return readText(path).strip;
	catch (Exception)
		return fallback;
}

version (unittest) import fluent.asserts;

unittest
{
	// URL construction is pure and worth pinning; building the client opens no
	// connection.
	auto client = new HttpKubeClient(ClusterConfig("https://api:443", "tok", "/ca", "ai-agents"));
	client.crUrl("ai-agents", "agents", "run-1").should.equal(
		"https://api:443/apis/agents.re-cinq.com/v1alpha1/namespaces/ai-agents/agents/run-1");
	client.crCollectionUrl("ai-agents", "stations").should.equal(
		"https://api:443/apis/agents.re-cinq.com/v1alpha1/namespaces/ai-agents/stations");
	client.jobUrl("ai-agents", "agent-job-run-1").should.equal(
		"https://api:443/apis/batch/v1/namespaces/ai-agents/jobs/agent-job-run-1");
	client.podLogUrl("ai-agents", "p1").should.equal(
		"https://api:443/api/v1/namespaces/ai-agents/pods/p1/log?container=agent&tailLines=10000");
	client.leaseUrl("ai-agents", "agent-controller").should.equal(
		"https://api:443/apis/coordination.k8s.io/v1/namespaces/ai-agents/leases/agent-controller");
}

unittest
{
	// The watch asks the server to close the long poll after timeoutSeconds, so a
	// silently dropped (half-open) connection can't wedge the watch indefinitely.
	watchQuery("12345", 300).should.equal("?watch=1&resourceVersion=12345&timeoutSeconds=300");
}

unittest
{
	// Every request carries connect + read timeouts so a stalled API server can't
	// wedge a reconcile fiber (and starve Lease renewal) forever. The watch gets a
	// read timeout longer than its server-side long poll, so it survives idle periods
	// but a half-open (silently dropped) connection still breaks instead of blocking
	// for hours.
	auto client = new HttpKubeClient(ClusterConfig("https://api:443", "tok", "", "/ca", "ai-agents"));
	client.settings.connectTimeout.should.equal(apiConnectTimeout);
	client.settings.readTimeout.should.equal(apiReadTimeout);
	(client.watchSettings.readTimeout > client.settings.readTimeout).should.equal(true);
}

unittest
{
	import std.file : write, remove, tempDir;
	import std.path : buildPath;

	// No path configured (out-of-cluster) -> keep the static fallback token.
	refreshToken("", "static-tok").should.equal("static-tok");

	// A rotated token file is re-read; a trailing newline is stripped.
	const path = buildPath(tempDir, "ai-agent-token-test");
	write(path, "rotated-tok\n");
	scope (exit)
		remove(path);
	refreshToken(path, "old-tok").should.equal("rotated-tok");

	// An unreadable path falls back to the last good token (never drops auth).
	refreshToken("/no/such/token/file", "old-tok").should.equal("old-tok");
}

unittest
{
	auto record = parseLeaseRecord(parseJsonString(`{"metadata":{"resourceVersion":"99"},
		"spec":{"holderIdentity":"pod-a","renewTime":"2026-06-23T00:00:00.000000Z","leaseTransitions":3}}`));
	record.should.equal(LeaseRecord(true, "pod-a", "2026-06-23T00:00:00.000000Z", "99", 3));

	// A Lease that has not been created yet leaves exists false and fields empty.
	LeaseRecord.init.should.equal(LeaseRecord(false, "", "", "", 0));
}
