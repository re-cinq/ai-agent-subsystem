module webhook;

import std.array : split;

import vibe.core.log : logError, logInfo;
import vibe.data.json : Json, parseJsonString;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse, HTTPServerSettings, listenHTTP;
import vibe.stream.operations : readAll;

import agentcore.crds.agent_spawner : AgentSpawner;
import agentcore.kube.jobspec : agentSecretName;
import agentcore.kube.kubeclient : NotFound;
import agentcore.spawner.github : agentFromDelivery, ignoredReason, signatureMatches, validDeliveryId;

import promptapi : Reply, failure;

version (unittest) import fluent.asserts;

/// The largest webhook body accepted; GitHub's issue payloads are a few tens of KiB.
enum maxWebhookBodyBytes = 1024 * 1024;

/// What the webhook receiver reads from the cluster and writes back to it.
interface WebhookCluster
{
	/// The AgentSpawner `name`; throws `NotFound` when it does not exist.
	AgentSpawner getAgentSpawner(string ns, string name);

	/// The base64-decoded `key` of the Secret `name`; throws `NotFound` when either is missing.
	string secretValue(string ns, string name, string key);

	/// Create an Agent; true when created, false when it already existed.
	bool createAgent(string ns, Json agent);
}

/// One webhook request as GitHub sends it: its event, delivery id and signature headers
/// and the raw body the signature covers.
struct Delivery
{
	string event;
	string id;
	string signature;
	string body_;
}

/// Answer the delivery to the AgentSpawner `ns/name`: verify it against the spawner's HMAC
/// secret, then start a run when its github trigger matches. The Agent is named after the
/// delivery, so a redelivery finds it already there and starts nothing.
Reply handleDelivery(WebhookCluster cluster, string servedNamespace, string ns, string name, const Delivery delivery)
{
	if (ns != servedNamespace)
		return failure(404, "this controller serves namespace " ~ servedNamespace);
	if (delivery.body_.length > maxWebhookBodyBytes)
		return failure(413, "request body too large");

	AgentSpawner spawner;
	try
		spawner = cluster.getAgentSpawner(ns, name);
	catch (NotFound)
		return failure(404, "AgentSpawner " ~ name ~ " not found");
	const trigger = spawner.spec.github;
	if (trigger.secretRef.length == 0)
		return failure(404, "AgentSpawner " ~ name ~ " has no github trigger");

	string secret;
	try
		secret = cluster.secretValue(ns, agentSecretName, trigger.secretRef);
	catch (Exception error)
	{
		logError("webhook for agent spawner %s: reading its secret %s: %s", name, trigger.secretRef, error.msg);
		return failure(500, "the spawner's webhook secret cannot be read");
	}
	if (!signatureMatches(secret, delivery.body_, delivery.signature))
		return failure(401, "missing or wrong X-Hub-Signature-256");

	if (delivery.event == "ping")
		return answer(200, ["status": Json("pong")]);
	if (!validDeliveryId(delivery.id))
		return failure(400, "missing or malformed X-GitHub-Delivery");
	Json payload;
	try
		payload = parseJsonString(delivery.body_);
	catch (Exception)
		return failure(400, "the body is not JSON; set the webhook's content type to application/json");
	if (payload.type != Json.Type.object)
		return failure(400, "the body is not a JSON object");

	const reason = spawner.spec.suspend ? "the spawner is suspended" : ignoredReason(trigger, delivery.event, payload);
	if (reason.length)
		return answer(202, ["ignored": Json(reason)]);
	return startRun(cluster, ns, spawner, agentFromDelivery(spawner, delivery.id, payload));
}

private Reply startRun(WebhookCluster cluster, string ns, const AgentSpawner spawner, Json agent)
{
	const agentName = agent["metadata"]["name"].get!string;
	bool created;
	try
		created = cluster.createAgent(ns, agent);
	catch (Exception error)
	{
		logError("webhook for agent spawner %s: creating %s: %s", spawner.metadata.name, agentName, error.msg);
		return failure(500, "creating the run failed");
	}
	if (created)
		logInfo("webhook for agent spawner %s: created %s", spawner.metadata.name, agentName);
	return answer(created ? 201 : 200, ["agent": Json(agentName), "created": Json(created)]);
}

private Reply answer(int status, Json[string] fields)
{
	return Reply(status, Json(fields).toString());
}

/// The namespace and AgentSpawner name of `/v1/namespaces/<ns>/agentspawners/<name>/github`,
/// or false when `path` is not one.
bool parseWebhookRoute(string path, out string ns, out string name) @safe pure
{
	const parts = path.split("/");
	if (parts.length != 7 || parts[0] != "" || parts[1] != "v1" || parts[2] != "namespaces"
		|| parts[4] != "agentspawners" || parts[6] != "github" || parts[3].length == 0 || parts[5].length == 0)
		return false;
	ns = parts[3];
	name = parts[5];
	return true;
}

/// Serve GitHub webhooks on `port`: `POST /v1/namespaces/<ns>/agentspawners/<name>/github`.
void startWebhookApi(ushort port, string namespace, WebhookCluster cluster)
{
	auto settings = new HTTPServerSettings;
	settings.port = port;
	settings.bindAddresses = ["0.0.0.0", "::"];
	// Twice the cap, so a body just over it reads and gets a 413 instead of vibe's 400.
	settings.maxRequestSize = 2 * maxWebhookBodyBytes;
	listenHTTP(settings, (scope HTTPServerRequest req, scope HTTPServerResponse res) @trusted {
		string ns, name;
		Reply reply = req.method == HTTPMethod.POST && parseWebhookRoute(req.requestPath.toString, ns, name)
			? handleDelivery(cluster, namespace, ns, name, Delivery(req.headers.get("X-GitHub-Event", ""),
				req.headers.get("X-GitHub-Delivery", ""), req.headers.get("X-Hub-Signature-256", ""),
				cast(string) req.bodyReader.readAll(2 * maxWebhookBodyBytes)))
			: failure(404, "not found");
		res.writeBody(reply.body, reply.status, "application/json");
	});
}

version (unittest)
{
	import std.digest : LetterCase, toHexString;
	import std.digest.hmac : hmac;
	import std.digest.sha : SHA256;
	import std.string : representation;

	private final class FakeCluster : WebhookCluster
	{
		AgentSpawner spawner;
		bool spawnerExists = true;
		string[string] secrets;
		bool[string] agents;
		string[] calls;

		AgentSpawner getAgentSpawner(string ns, string name)
		{
			calls ~= "get " ~ name;
			if (!spawnerExists)
				throw new NotFound("AgentSpawner " ~ name ~ " not found");
			return spawner;
		}

		string secretValue(string ns, string name, string key)
		{
			calls ~= "secret " ~ name ~ "/" ~ key;
			if (key !in secrets)
				throw new NotFound("Secret has no key " ~ key);
			return secrets[key];
		}

		bool createAgent(string ns, Json agent)
		{
			const agentName = agent["metadata"]["name"].get!string;
			calls ~= "create " ~ agentName ~ " " ~ agent["spec"]["parameters"]["issue_title"].get!string;
			if (agentName in agents)
				return false;
			agents[agentName] = true;
			return true;
		}
	}

	private enum labeled = `{"action":"labeled","label":{"name":"agent"},
		"issue":{"number":42,"title":"Crash on start","body":"b","html_url":"https://github.com/octo/app/issues/42"},
		"repository":{"full_name":"octo/app"}}`;

	private FakeCluster fixerCluster()
	{
		auto cluster = new FakeCluster;
		cluster.spawner.metadata.name = "fixer";
		cluster.spawner.metadata.namespace = "ai-agents";
		cluster.spawner.spec.stationRef = "bug-fixer";
		cluster.spawner.spec.github.secretRef = "github-webhook";
		cluster.spawner.spec.github.events = ["issues.labeled"];
		cluster.spawner.spec.github.label = "agent";
		cluster.secrets = ["github-webhook": "s3cret"];
		return cluster;
	}

	private Delivery signed(string body_, string event = "issues", string id = "d-1", string secret = "s3cret")
	{
		const mac = body_.representation.hmac!SHA256(secret.representation);
		return Delivery(event, id, "sha256=" ~ toHexString!(LetterCase.lower)(mac).idup, body_);
	}

	private Reply deliver(FakeCluster cluster, const Delivery delivery, string ns = "ai-agents")
	{
		return handleDelivery(cluster, "ai-agents", ns, "fixer", delivery);
	}
}

unittest // a signed issues.labeled delivery creates the run named after it (201); its redelivery creates none (200)
{
	auto cluster = fixerCluster();
	const first = deliver(cluster, signed(labeled));
	const again = deliver(cluster, signed(labeled));

	[first.status, again.status].should.equal([201, 200]);
	[parseJsonString(first.body), parseJsonString(again.body)].should.equal([
		parseJsonString(`{"agent":"fixer-d-1","created":true}`), parseJsonString(`{"agent":"fixer-d-1","created":false}`)
	]);
	cluster.calls.should.equal(["get fixer", "secret agent-secrets/github-webhook", "create fixer-d-1 Crash on start",
		"get fixer", "secret agent-secrets/github-webhook", "create fixer-d-1 Crash on start"]);
}

unittest // a wrong, unsigned or other-secret signature is refused 401 and creates nothing
{
	auto cluster = fixerCluster();
	auto unsigned = signed(labeled);
	unsigned.signature = "";
	auto tampered = signed(labeled);
	tampered.body_ = labeled ~ " ";

	[deliver(cluster, unsigned).status, deliver(cluster, tampered).status,
		deliver(cluster, signed(labeled, "issues", "d-1", "guess")).status].should.equal([401, 401, 401]);
	cluster.agents.length.should.equal(0);
}

unittest // an unknown spawner, one without a github trigger, or another namespace is 404 and reads no secret
{
	auto missing = fixerCluster();
	missing.spawnerExists = false;
	auto cronOnly = fixerCluster();
	cronOnly.spawner.spec.github.secretRef = "";
	auto otherNamespace = fixerCluster();

	[deliver(missing, signed(labeled)).status, deliver(cronOnly, signed(labeled)).status,
		deliver(otherNamespace, signed(labeled), "default").status].should.equal([404, 404, 404]);
	(missing.calls ~ cronOnly.calls ~ otherNamespace.calls).should.equal(["get fixer", "get fixer"]);
}

unittest // a spawner whose secret key is missing answers 500 without saying which key
{
	auto cluster = fixerCluster();
	cluster.secrets = null;
	const reply = deliver(cluster, signed(labeled));
	[reply.status == 500, reply.body == `{"error":"the spawner's webhook secret cannot be read"}`]
		.should.equal([true, true]);
}

unittest // a body over 1 MiB is refused 413 before any cluster call
{
	import std.array : replicate;

	auto cluster = fixerCluster();
	deliver(cluster, signed("x".replicate(maxWebhookBodyBytes + 1))).status.should.equal(413);
	cluster.calls.length.should.equal(0);
}

unittest // a signed ping answers 200 and starts nothing
{
	auto cluster = fixerCluster();
	const reply = deliver(cluster, signed(`{"zen":"Keep it logically awesome."}`, "ping", ""));
	[reply.status == 200, reply.body == `{"status":"pong"}`, cluster.agents.length == 0].should.equal([true, true, true]);
}

unittest // a signed delivery of another action, another label or to a suspended spawner is 202 with the reason
{
	auto cluster = fixerCluster();
	const closed = deliver(cluster, signed(`{"action":"closed"}`));
	const otherLabel = deliver(cluster, signed(`{"action":"labeled","label":{"name":"bug"}}`));
	cluster.spawner.spec.suspend = true;
	const suspended = deliver(cluster, signed(labeled));

	[closed.status, otherLabel.status, suspended.status].should.equal([202, 202, 202]);
	[closed.body, otherLabel.body, suspended.body].should.equal([
		`{"ignored":"issues.closed is not one of the spawner's events"}`, `{"ignored":"the label added is not agent"}`,
		`{"ignored":"the spawner is suspended"}`
	]);
	cluster.agents.length.should.equal(0);
}

unittest // a signed delivery without a delivery id, or with a form-encoded body, is 400
{
	auto cluster = fixerCluster();
	[deliver(cluster, signed(labeled, "issues", "")).status, deliver(cluster, signed("payload=%7B%7D")).status,
		deliver(cluster, signed(`[1]`)).status].should.equal([400, 400, 400]);
}

@safe unittest // only the github route of a namespaced AgentSpawner parses
{
	string ns, name;
	const github = parseWebhookRoute("/v1/namespaces/ai-agents/agentspawners/fixer/github", ns, name);
	const parsed = [ns, name];

	[github, parseWebhookRoute("/v1/namespaces/ai-agents/agentspawners/fixer/gitlab", ns, name),
		parseWebhookRoute("/v1/namespaces/ai-agents/agents/fixer/github", ns, name),
		parseWebhookRoute("/v1/namespaces//agentspawners/fixer/github", ns, name)]
		.should.equal([true, false, false, false]);
	parsed.should.equal(["ai-agents", "fixer"]);
}
