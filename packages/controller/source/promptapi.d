module promptapi;

import core.time : seconds;
import std.algorithm.searching : canFind;
import std.array : split;
import std.conv : to;

import vibe.core.log : logError;
import vibe.data.json : Json, parseJsonString;
import vibe.http.client : HTTPClientRequest, HTTPClientResponse, HTTPClientSettings, requestHTTP;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse, HTTPServerSettings, listenHTTP;
import vibe.stream.operations : readAllUTF8;

import agentcore.core.env : defaultRealtimePort, maxRealtimePromptBytes;
import agentcore.core.token : bearerOf, runToken, tokenMatches;
import agentcore.core.types : Phase;
import agentcore.crds.agent : Agent;
import agentcore.kube.jobspec : labelExecution;
import agentcore.kube.kubeclient : NotFound;

import httpkube : HttpKubeClient;

version (unittest) import fluent.asserts;

/// The run pod of an Agent's Job, as far as routing a prompt to it needs.
struct PodEndpoint
{
	bool found;
	string ip;
	string phase;
	bool realtime;
}

/// The run pod in a Job's pod `list`: its IP, phase and whether it runs a realtime session.
PodEndpoint podEndpointOf(Json list)
{
	if (list.type != Json.Type.object || "items" !in list || list["items"].type != Json.Type.array
		|| list["items"].length == 0)
		return PodEndpoint.init;
	auto pod = list["items"][0];
	auto labels = pod["metadata"]["labels"];
	const realtime = labels.type == Json.Type.object && labelExecution in labels
		&& labels[labelExecution].get!string == "realtime";
	return PodEndpoint(true, pod["status"]["podIP"].opt!string(""), pod["status"]["phase"].opt!string(""), realtime);
}

/// What the prompt API reads from the cluster and writes back to it.
interface PromptCluster
{
	/// The Agent `name`; throws `NotFound` when it does not exist.
	Agent agent(string ns, string name);
	PodEndpoint runPod(string ns, string jobName);
	void recordSession(string ns, string name, string sessionId);
}

/// The cluster through the controller's own API client.
final class KubePromptCluster : PromptCluster
{
	private HttpKubeClient client;

	this(HttpKubeClient client)
	{
		this.client = client;
	}

	Agent agent(string ns, string name)
	{
		return client.getAgent(ns, name);
	}

	PodEndpoint runPod(string ns, string jobName)
	{
		return podEndpointOf(client.podsForJob(ns, jobName));
	}

	void recordSession(string ns, string name, string sessionId)
	{
		client.patchAgentStatus(ns, name, sessionPatch(sessionId));
	}
}

/// An HTTP answer: its status, JSON body and, for a 503, when to retry.
struct Reply
{
	int status;
	string body;
	int retryAfter;
}

/// Sends `body_` to a run pod's supervisor at `url` with `token`; status 0 when it cannot be reached.
alias Forward = Reply delegate(string url, string token, string body_);

/// The prompt API's own settings: the namespace it serves, the bearer callers present,
/// and the key run tokens are derived from.
struct PromptApiConfig
{
	string namespace;
	string apiToken;
	string signingKey;
}

/// Answer `action` (`prompt` or `close`) for the Agent `ns/name`: check the caller's
/// bearer, find the Agent's realtime run pod, and forward `body_` to its supervisor. A
/// prompt's 202 carries the session id, which is recorded on the Agent when it changed.
Reply handle(const PromptApiConfig config, PromptCluster cluster, Forward forward, string ns, string name,
	string action, string authorization, string body_)
{
	if (!tokenMatches(bearerOf(authorization), config.apiToken))
		return failure(401, "missing or wrong bearer token");
	if (body_.length > 2 * maxRealtimePromptBytes)
		return failure(413, "request body too large");
	if (ns != config.namespace)
		return failure(404, "this controller serves namespace " ~ config.namespace);

	Agent agent;
	try
		agent = cluster.agent(ns, name);
	catch (NotFound)
		return failure(404, "Agent " ~ name ~ " not found");
	if (agent.status.phase != Phase.running || agent.status.jobName.length == 0)
		return failure(409, "Agent " ~ name ~ " is " ~ phaseName(agent.status.phase) ~ ", not a running session");

	const pod = cluster.runPod(ns, agent.status.jobName);
	if (pod.found && !pod.realtime)
		return failure(409, "Agent " ~ name ~ " is not a realtime run");
	if (!pod.found || pod.phase != "Running" || pod.ip.length == 0)
		return Reply(503, Json(["error": Json("the session is not serving yet")]).toString(), 2);

	auto reply = forward(supervisorUrl(pod.ip, action), runToken(config.signingKey, agent.metadata.uid), body_);
	if (reply.status == 0)
		return Reply(503, Json(["error": Json("the session's pod cannot be reached")]).toString(), 2);
	if (![202, 400, 409, 413, 429].canFind(reply.status))
		return failure(502, "the session answered " ~ reply.status.to!string);
	if (action == "prompt" && reply.status == 202)
		recordSessionChange(cluster, ns, agent, reply.body);
	return reply;
}

/// The status patch recording `sessionId` on an Agent.
Json sessionPatch(string sessionId)
{
	return Json(["status": Json(["sessionId": Json(sessionId)])]);
}

private void recordSessionChange(PromptCluster cluster, string ns, const Agent agent, string replyBody)
{
	try
	{
		const sessionId = parseJsonString(replyBody)["sessionId"].opt!string("");
		if (sessionId.length && sessionId != agent.status.sessionId)
			cluster.recordSession(ns, agent.metadata.name, sessionId);
	}
	catch (Exception e)
		logError("recording the session id of %s failed: %s", agent.metadata.name, e.msg);
}

private string supervisorUrl(string ip, string action)
{
	const host = ip.canFind(':') ? "[" ~ ip ~ "]" : ip;
	return "http://" ~ host ~ ":" ~ defaultRealtimePort.to!string ~ "/v1/" ~ action;
}

private string phaseName(Phase phase)
{
	return phase.length ? cast(string) phase : cast(string) Phase.pending;
}

private Reply failure(int status, string message)
{
	return Reply(status, Json(["error": Json(message)]).toString());
}

/// The namespace, Agent name and action of `/v1/namespaces/<ns>/agents/<name>/<prompt|close>`,
/// or false when `path` is not one.
bool parseRoute(string path, out string ns, out string name, out string action) @safe pure
{
	const parts = path.split("/");
	if (parts.length != 7 || parts[0] != "" || parts[1] != "v1" || parts[2] != "namespaces" || parts[4] != "agents"
		|| (parts[6] != "prompt" && parts[6] != "close") || parts[3].length == 0 || parts[5].length == 0)
		return false;
	ns = parts[3];
	name = parts[5];
	action = parts[6];
	return true;
}

/// Serve the prompt API on `port`: `POST /v1/namespaces/<ns>/agents/<name>/prompt` and
/// `…/close`, forwarded to the Agent's realtime run pod.
void startPromptApi(ushort port, const PromptApiConfig config, PromptCluster cluster)
{
	auto settings = new HTTPServerSettings;
	settings.port = port;
	settings.bindAddresses = ["0.0.0.0", "::"];
	settings.maxRequestSize = 2 * maxRealtimePromptBytes + 4096;
	listenHTTP(settings, (scope HTTPServerRequest req, scope HTTPServerResponse res) @trusted {
		string ns, name, action;
		Reply reply = req.method == HTTPMethod.POST && parseRoute(req.requestPath.toString, ns, name, action)
			? handle(config, cluster, (url, token, body_) => forwardToPod(url, token, body_), ns, name, action,
				req.headers.get("Authorization", ""), req.bodyReader.readAllUTF8())
			: failure(404, "not found");
		if (reply.retryAfter)
			res.headers["Retry-After"] = reply.retryAfter.to!string;
		res.writeBody(reply.body, reply.status, "application/json");
	});
}

/// POST `body_` to a run pod's supervisor; status 0 when the pod cannot be reached.
private Reply forwardToPod(string url, string token, string body_)
{
	auto settings = new HTTPClientSettings;
	settings.connectTimeout = 5.seconds;
	settings.readTimeout = 10.seconds;
	Reply reply;
	try
		requestHTTP(url,
			(scope HTTPClientRequest req) {
				req.method = HTTPMethod.POST;
				req.headers["Authorization"] = "Bearer " ~ token;
				req.writeBody(cast(const(ubyte)[]) body_, "application/json");
			},
			(scope HTTPClientResponse res) {
				reply.status = res.statusCode;
				reply.body = res.bodyReader.readAllUTF8();
			},
			settings);
	catch (Exception e)
	{
		logError("forwarding to %s failed: %s", url, e.msg);
		reply.status = 0;
	}
	return reply;
}

version (unittest)
{
	private final class FakeCluster : PromptCluster
	{
		Agent stored;
		bool exists = true;
		PodEndpoint pod = PodEndpoint(true, "10.1.2.3", "Running", true);
		string[] recorded;

		Agent agent(string ns, string name)
		{
			if (!exists)
				throw new NotFound("Agent " ~ name ~ " not found");
			return stored;
		}

		PodEndpoint runPod(string ns, string jobName)
		{
			return pod;
		}

		void recordSession(string ns, string name, string sessionId)
		{
			recorded ~= name ~ "=" ~ sessionId;
		}
	}

	private struct FakePod
	{
		Reply answer = Reply(202, `{"turn":1,"queued":1,"sessionId":"sess-1"}`);
		string[] calls;

		Reply forward(string url, string token, string body_)
		{
			calls ~= url ~ " " ~ token ~ " " ~ body_;
			return answer;
		}
	}

	private enum config = PromptApiConfig("ai-agents", "api-1", "key");

	private FakeCluster runningSession()
	{
		auto cluster = new FakeCluster;
		cluster.stored.metadata.name = "run-1";
		cluster.stored.metadata.uid = "uid-1";
		cluster.stored.status.phase = Phase.running;
		cluster.stored.status.jobName = "agent-job-run-1";
		return cluster;
	}

	private Reply send(FakeCluster cluster, ref FakePod pod, string action = "prompt",
		string authorization = "Bearer api-1", string ns = "ai-agents")
	{
		return handle(config, cluster, &pod.forward, ns, "run-1", action, authorization, `{"prompt":"hi"}`);
	}
}

unittest // a prompt to a running realtime session is forwarded with the run's token and its 202 passed back
{
	auto cluster = runningSession();
	FakePod pod;

	const reply = send(cluster, pod);

	[reply.status == 202, reply.body == pod.answer.body].should.equal([true, true]);
	pod.calls.should.equal(["http://10.1.2.3:8090/v1/prompt " ~ runToken("key", "uid-1") ~ ` {"prompt":"hi"}`]);
}

unittest // a prompt that reveals a new session id records it on the Agent, an unchanged one does not
{
	auto cluster = runningSession();
	FakePod pod;
	send(cluster, pod);
	cluster.stored.status.sessionId = "sess-1";
	send(cluster, pod);

	cluster.recorded.should.equal(["run-1=sess-1"]);
}

unittest // a close is forwarded to the supervisor's close route and records nothing
{
	auto cluster = runningSession();
	FakePod pod;
	pod.answer = Reply(202, `{"queued":0}`);

	const reply = send(cluster, pod, "close");

	[reply.status, cast(int) cluster.recorded.length].should.equal([202, 0]);
	pod.calls[0].should.startWith("http://10.1.2.3:8090/v1/close ");
}

unittest // callers without the API token, of another namespace, or of a missing Agent are refused before any forward
{
	auto cluster = runningSession();
	FakePod pod;
	const unauthorized = send(cluster, pod, "prompt", "Bearer nope");
	const otherNamespace = send(cluster, pod, "prompt", "Bearer api-1", "default");
	cluster.exists = false;
	const missing = send(cluster, pod);

	[unauthorized.status, otherNamespace.status, missing.status].should.equal([401, 404, 404]);
	pod.calls.length.should.equal(0);
}

unittest // an Agent that is not a running realtime session is refused 409
{
	auto pending = runningSession();
	pending.stored.status.phase = Phase.pending;
	auto interactive = runningSession();
	interactive.pod.realtime = false;
	FakePod pod;

	[send(pending, pod).status, send(interactive, pod).status].should.equal([409, 409]);
	parseJsonString(send(pending, pod).body)["error"].get!string
		.should.equal("Agent run-1 is Pending, not a running session");
}

unittest // a session whose pod is not serving yet or cannot be reached is 503 with a retry hint
{
	auto starting = runningSession();
	starting.pod = PodEndpoint(true, "", "Pending", true);
	auto unreachable = runningSession();
	FakePod pod;
	FakePod down;
	down.answer = Reply(0, "");

	const notYet = send(starting, pod);
	const gone = send(unreachable, down);

	[notYet.status, notYet.retryAfter, gone.status, gone.retryAfter].should.equal([503, 2, 503, 2]);
}

unittest // the supervisor's refusals pass through and anything unexpected is 502
{
	FakePod pod;
	int answered(int status)
	{
		pod.answer = Reply(status, `{"error":"x"}`);
		return send(runningSession(), pod).status;
	}

	[answered(429), answered(409), answered(401), answered(500)].should.equal([429, 409, 502, 502]);
}

unittest // a pod list yields its first pod's IP, phase and realtime label
{
	const list = parseJsonString(`{"items":[{"metadata":{"labels":{"agents.re-cinq.com/execution":"realtime"}},
		"status":{"podIP":"10.0.0.7","phase":"Running"}}]}`);

	[podEndpointOf(list) == PodEndpoint(true, "10.0.0.7", "Running", true),
		podEndpointOf(parseJsonString(`{"items":[]}`)) == PodEndpoint.init,
		podEndpointOf(parseJsonString(`{"items":[{"metadata":{},"status":{}}]}`)) == PodEndpoint(true, "", "", false)]
		.should.equal([true, true, true]);
}

unittest // an IPv6 pod address is bracketed in the supervisor URL
{
	supervisorUrl("fd00::7", "prompt").should.equal("http://[fd00::7]:8090/v1/prompt");
}

@safe unittest // only the prompt and close routes of a namespaced Agent parse
{
	string ns, name, action;
	const prompt = parseRoute("/v1/namespaces/ai-agents/agents/run-1/prompt", ns, name, action);
	const parsed = [ns, name, action];

	[prompt, parseRoute("/v1/namespaces/ai-agents/agents/run-1/other", ns, name, action),
		parseRoute("/v1/namespaces//agents/run-1/close", ns, name, action), parseRoute("/v1/prompt", ns, name, action)]
		.should.equal([true, false, false, false]);
	parsed.should.equal(["ai-agents", "run-1", "prompt"]);
}
