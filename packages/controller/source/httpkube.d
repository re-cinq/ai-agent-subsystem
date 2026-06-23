module httpkube;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;

import vibe.http.client : HTTPClientRequest, HTTPClientResponse, HTTPClientSettings, requestHTTP;
import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAllUTF8, readLine;
import vibe.stream.tls : TLSContext;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.station : Station;
import agentcore.kube.jsonbody : parseAgent, parseAgentDefinition, parseAgentList, parseJobOutcome, parseStation;
import agentcore.kube.kubeclient : KubeClient, NotFound, PodResult;
import agentcore.kube.outputcap : capOutput;
import agentcore.reconcile.reconcile : JobOutcome;

import incluster : ClusterConfig;

enum crGroup = "agents.re-cinq.com";
enum crVersion = "v1alpha1";

/// Last lines requested from a pod's log: a coarse cap on what crosses the wire.
/// The byte-accurate tail kept in status.output is enforced by `capOutput`.
enum logTailLines = 10_000;

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

/// `KubeClient` over the Kubernetes API server, spoken with vibe's HTTP client:
/// bearer-token auth, the cluster CA added to the TLS trust store, and
/// merge-patch for the status subresource. The long-lived watch stream
/// (`watchAgents`) is controller-only and sits beside the interface.
final class HttpKubeClient : KubeClient
{
	private ClusterConfig config;
	private HTTPClientSettings settings;

	this(ClusterConfig config)
	{
		this.config = config;
		this.settings = new HTTPClientSettings;
		const ca = config.caFile;
		this.settings.tlsContextSetup = (TLSContext ctx) @safe nothrow {
			try
				() @trusted { ctx.useTrustedCertificateFile(ca); }();
			catch (Exception)
			{
			}
		};
	}

	override Station getStation(string ns, string name)
	{
		return parseStation(getJson(crUrl(ns, "stations", name), "Station " ~ name));
	}

	override AgentDefinition getAgentDefinition(string ns, string name)
	{
		return parseAgentDefinition(getJson(crUrl(ns, "agentdefinitions", name), "AgentDefinition " ~ name));
	}

	override void createJob(string ns, JSONValue job)
	{
		send(HTTPMethod.POST, jobsUrl(ns), job, "application/json", [201, 409]);
	}

	override JobOutcome jobOutcome(string ns, string jobName)
	{
		return parseJobOutcome(getJson(jobUrl(ns, jobName), "Job " ~ jobName));
	}

	override void patchAgentStatus(string ns, string name, JSONValue statusPatch)
	{
		send(HTTPMethod.PATCH, crUrl(ns, "agents", name) ~ "/status", statusPatch,
			"application/merge-patch+json", [200]);
	}

	override Agent[] listAgents(string ns)
	{
		return parseAgentList(getJson(crCollectionUrl(ns, "agents"), "agents"));
	}

	override void deleteAgent(string ns, string name)
	{
		send(HTTPMethod.DELETE, crUrl(ns, "agents", name), JSONValue.init, "", [200, 202, 404]);
	}

	override string podNameForJob(string ns, string jobName)
	{
		auto list = getJson(podsUrl(ns) ~ "?labelSelector=job-name=" ~ jobName, "pods for " ~ jobName);
		if (list.type == JSONType.object)
			if (auto items = "items" in list.object)
				if (items.type == JSONType.array && items.array.length)
					return items.array[0]["metadata"]["name"].str;
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
	/// `onLine` until the connection ends. `resourceVersion` "0" replays the
	/// current state then follows changes.
	void watchAgents(string ns, string resourceVersion, scope void delegate(string line) onLine)
	{
		const url = crCollectionUrl(ns, "agents") ~ "?watch=1&resourceVersion=" ~ resourceVersion;
		requestHTTP(url,
			(scope HTTPClientRequest req) { authorize(req); },
			(scope HTTPClientResponse res) {
				while (!res.bodyReader.empty)
				{
					auto line = cast(string) res.bodyReader.readLine(size_t.max, "\n");
					if (line.length)
						onLine(line);
				}
			}, settings);
	}

	/// Read the leader-election Lease. A 404 means none has been created yet,
	/// reported as `exists = false` rather than thrown — that is the signal to
	/// create one.
	LeaseRecord getLease(string ns, string name)
	{
		JSONValue document;
		int status;
		requestHTTP(leaseUrl(ns, name),
			(scope HTTPClientRequest req) { authorize(req); },
			(scope HTTPClientResponse res) {
				status = res.statusCode;
				const body = res.bodyReader.readAllUTF8();
				if (status == 200)
					document = parseJSON(body);
			}, settings);
		if (status == 404)
			return LeaseRecord.init;
		enforce(status == 200, "Lease " ~ name ~ ": unexpected status " ~ status.to!string);
		return parseLeaseRecord(document);
	}

	/// Create the Lease. Returns true when we created it (201); a 409 means another
	/// replica created it first, so we did not win leadership.
	bool createLease(string ns, JSONValue body)
	{
		return send(HTTPMethod.POST, leasesUrl(ns), body, "application/json", [201, 409]) == 201;
	}

	/// Merge-patch the Lease (renew or takeover). Returns true when the write landed
	/// (200); a 409 means our resourceVersion was stale — another replica wrote
	/// first — so we did not hold or take leadership this tick.
	bool patchLease(string ns, string name, JSONValue body)
	{
		return send(HTTPMethod.PATCH, leaseUrl(ns, name), body, "application/merge-patch+json",
			[200, 409]) == 200;
	}

	private JSONValue getJson(string url, string what)
	{
		JSONValue document;
		int status;
		requestHTTP(url,
			(scope HTTPClientRequest req) { authorize(req); },
			(scope HTTPClientResponse res) {
				status = res.statusCode;
				const body = res.bodyReader.readAllUTF8();
				if (status == 200)
					document = parseJSON(body);
			}, settings);
		if (status == 404)
			throw new NotFound(what ~ " not found");
		enforce(status == 200, what ~ ": unexpected status " ~ status.to!string);
		return document;
	}

	private string getText(string url, string what)
	{
		string body;
		int status;
		requestHTTP(url,
			(scope HTTPClientRequest req) { authorize(req); },
			(scope HTTPClientResponse res) {
				status = res.statusCode;
				body = res.bodyReader.readAllUTF8();
			}, settings);
		enforce(status == 200, what ~ ": unexpected status " ~ status.to!string);
		return body;
	}

	/// The `agent` container's terminated exit code from a pod object, or 0 when it
	/// is not present (pod still running, or already GC'd).
	private int agentExitCode(JSONValue pod)
	{
		if (pod.type != JSONType.object)
			return 0;
		auto status = "status" in pod.object;
		if (status is null || status.type != JSONType.object)
			return 0;
		auto containers = "containerStatuses" in status.object;
		if (containers is null || containers.type != JSONType.array)
			return 0;
		foreach (container; containers.array)
		{
			if (container.type != JSONType.object)
				continue;
			auto name = "name" in container.object;
			if (name is null || name.str != "agent")
				continue;
			auto state = "state" in container.object;
			if (state is null || state.type != JSONType.object)
				continue;
			auto terminated = "terminated" in state.object;
			if (terminated is null || terminated.type != JSONType.object)
				continue;
			auto code = "exitCode" in terminated.object;
			if (code !is null && code.type == JSONType.integer)
				return cast(int) code.integer;
		}
		return 0;
	}

	private int send(HTTPMethod method, string url, JSONValue body, string contentType, int[] okCodes)
	{
		int status;
		requestHTTP(url,
			(scope HTTPClientRequest req) {
				req.method = method;
				authorize(req);
				if (body.type != JSONType.null_)
					req.writeBody(cast(const(ubyte)[]) body.toString(), contentType);
			},
			(scope HTTPClientResponse res) { status = res.statusCode; res.dropBody(); },
			settings);
		enforce(okCodes.canFind(status), url ~ ": unexpected status " ~ status.to!string);
		return status;
	}

	private void authorize(scope HTTPClientRequest req)
	{
		if (config.token.length)
			req.headers["Authorization"] = "Bearer " ~ config.token;
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
		return podUrl(ns, name) ~ "/log?tailLines=" ~ logTailLines.to!string;
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
LeaseRecord parseLeaseRecord(JSONValue lease)
{
	LeaseRecord record;
	record.exists = true;
	record.resourceVersion = leaseField(lease, "metadata", "resourceVersion");
	record.holder = leaseField(lease, "spec", "holderIdentity");
	record.renewTime = leaseField(lease, "spec", "renewTime");
	record.transitions = cast(int) leaseTransitions(lease);
	return record;
}

private string leaseField(JSONValue lease, string section, string key)
{
	auto value = leaseSection(lease, section, key);
	return (value !is null && value.type == JSONType.string) ? value.str : "";
}

private long leaseTransitions(JSONValue lease)
{
	auto value = leaseSection(lease, "spec", "leaseTransitions");
	return (value !is null && value.type == JSONType.integer) ? value.integer : 0;
}

private JSONValue* leaseSection(JSONValue lease, string section, string key)
{
	if (lease.type != JSONType.object)
		return null;
	auto sec = section in lease.object;
	if (sec is null || sec.type != JSONType.object)
		return null;
	return key in sec.object;
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
		"https://api:443/api/v1/namespaces/ai-agents/pods/p1/log?tailLines=10000");
	client.leaseUrl("ai-agents", "agent-controller").should.equal(
		"https://api:443/apis/coordination.k8s.io/v1/namespaces/ai-agents/leases/agent-controller");
}

unittest
{
	auto record = parseLeaseRecord(parseJSON(`{"metadata":{"resourceVersion":"99"},
		"spec":{"holderIdentity":"pod-a","renewTime":"2026-06-23T00:00:00.000000Z","leaseTransitions":3}}`));
	record.should.equal(LeaseRecord(true, "pod-a", "2026-06-23T00:00:00.000000Z", "99", 3));

	// A Lease that has not been created yet leaves exists false and fields empty.
	LeaseRecord.init.should.equal(LeaseRecord(false, "", "", "", 0));
}
