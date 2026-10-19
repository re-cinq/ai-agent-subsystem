/// AgentSpawner GitHub triggers: which signed webhook deliveries start a run, and the Agent
/// a delivery creates. The Agent is named after the delivery, so a GitHub redelivery 409s
/// instead of starting a second run.
module agentcore.spawner.github;

import std.algorithm.searching : all, canFind, startsWith;
import std.ascii : isAlphaNum;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.hmac : hmac;
import std.digest.sha : SHA256;
import std.string : representation;
import std.uni : sicmp, toLower, toUpper;

import vibe.data.json : Json;

import agentcore.core.env : paramGitCredential, paramGitCredentialUrl;
import agentcore.core.token : tokenMatches;
import agentcore.crds.agent_spawner : AgentSpawner, GitHubTrigger;
import agentcore.crds.api_group : crGroup;
import agentcore.kube.jobs : safeName;
import agentcore.spawner.spawner : spawnedAgent;

/// Label on every Agent a webhook delivery started; its value is the X-GitHub-Delivery id.
enum githubDeliveryLabel = crGroup ~ "/github-delivery";

/// Whether `signature`, an X-Hub-Signature-256 header value, is `sha256=` and the lowercase
/// hex HMAC-SHA256 of `body_` under `secret`, compared in time independent of where they
/// differ. An empty secret verifies nothing.
bool signatureMatches(string secret, string body_, string signature) @safe
{
	enum scheme = "sha256=";
	if (secret.length == 0 || !signature.startsWith(scheme))
		return false;
	auto mac = body_.representation.hmac!SHA256(secret.representation);
	return tokenMatches(signature[scheme.length .. $], toHexString!(LetterCase.lower)(mac).idup);
}

/// Whether `id` is usable in an Agent name and a label value: 1 to 63 letters, digits and
/// dashes, starting and ending with a letter or digit. GitHub's delivery ids are UUIDs.
bool validDeliveryId(string id) @safe pure
{
	return id.length > 0 && id.length <= 63 && id.representation.all!(c => isAlphaNum(c) || c == '-')
		&& isAlphaNum(id[0]) && isAlphaNum(id[$ - 1]);
}

/// Why `trigger` ignores a delivery of `event` carrying `payload`, or "" when it starts a run.
string ignoredReason(const GitHubTrigger trigger, string event, const Json payload)
{
	const action = textAt(payload, "action");
	const delivered = action.length ? event ~ "." ~ action : event;
	if (!trigger.events.canFind(delivered))
		return delivered ~ " is not one of the spawner's events";
	const repository = textAt(payload, "repository", "full_name");
	if (trigger.repository.length && sicmp(repository, trigger.repository) != 0)
		return "repository " ~ repository ~ " is not " ~ trigger.repository;
	if (trigger.label.length && !carriesLabel(payload, action, trigger.label))
		return (action == "labeled" ? "the label added is not " : "the issue does not carry the label ") ~ trigger.label;
	return "";
}

/// For a `labeled` delivery, whether the label just added is `label`; for any other, whether
/// the issue carries it.
private bool carriesLabel(const Json payload, string action, string label)
{
	if (action == "labeled")
		return textAt(payload, "label", "name") == label;
	const labels = valueAt(payload, "issue", "labels");
	if (labels.type != Json.Type.array)
		return false;
	foreach (entry; labels.get!(Json[]))
		if (textAt(entry, "name") == label)
			return true;
	return false;
}

/// The Agent parameters a delivery starts its run with: the spawner's parameters as the
/// template, with the issue's number, title, body and URL and the repository over them.
/// The git credential parameters are dropped: a webhook run never carries broker credentials.
string[string] deliveryParameters(const AgentSpawner spawner, const Json payload)
{
	string[string] parameters;
	foreach (key, value; spawner.spec.parameters)
		if (key != paramGitCredential && key != paramGitCredentialUrl)
			parameters[key] = value;
	parameters["issue_number"] = textAt(payload, "issue", "number");
	parameters["issue_title"] = textAt(payload, "issue", "title");
	parameters["issue_body"] = textAt(payload, "issue", "body");
	parameters["issue_url"] = textAt(payload, "issue", "html_url");
	parameters["repo"] = textAt(payload, "repository", "full_name");
	return parameters;
}

/// `<spawner>-<delivery id, lowercased>`, shortened with a hash past 63 characters.
string deliveryAgentName(const AgentSpawner spawner, string deliveryId)
{
	return safeName(spawner.metadata.name ~ "-" ~ deliveryId.toLower);
}

/// The Agent the delivery `deliveryId` of `payload` starts: owned and labelled like a
/// scheduled run, also labelled with the delivery, with the repository as its targetRepo.
Json agentFromDelivery(const AgentSpawner spawner, string deliveryId, const Json payload)
{
	auto agent = spawnedAgent(spawner, deliveryAgentName(spawner, deliveryId), deliveryParameters(spawner, payload));
	agent["metadata"]["labels"][githubDeliveryLabel] = deliveryId;
	const repository = textAt(payload, "repository", "full_name");
	if (repository.length)
		agent["spec"]["targetRepo"] = repository;
	return agent;
}

/// The value at `path` under `json`, or undefined when a step is missing or not an object.
private const(Json) valueAt(const Json json, string[] path...)
{
	if (path.length == 0)
		return json;
	if (json.type != Json.Type.object)
		return Json.undefined;
	return valueAt(json[path[0]], path[1 .. $]);
}

/// The string or integer at `path` under `json` as text, or "" for anything else.
private string textAt(const Json json, string[] path...)
{
	const value = valueAt(json, path);
	if (value.type == Json.Type.string)
		return value.get!string;
	if (value.type == Json.Type.int_)
		return value.get!long.to!string;
	return "";
}

version (unittest)
{
	import fluent.asserts;
	import vibe.data.json : parseJsonString;

	private AgentSpawner webhookSpawner()
	{
		AgentSpawner spawner;
		spawner.metadata.name = "fixer";
		spawner.metadata.namespace = "ai-agents";
		spawner.metadata.uid = "uid-1";
		spawner.spec.stationRef = "bug-fixer";
		spawner.spec.github.secretRef = "github-webhook";
		spawner.spec.github.events = ["issues.labeled", "issues.opened"];
		spawner.spec.parameters = ["tone": "terse", "issue_title": "template title"];
		return spawner;
	}

	private enum labeledPayload = `{"action":"labeled","label":{"name":"agent"},
		"issue":{"number":42,"title":"Crash on start","body":"It crashes.",
			"html_url":"https://github.com/octo/app/issues/42", "labels":[{"name":"bug"},{"name":"agent"}]},
		"repository":{"full_name":"octo/app"}}`;

	private string hexHmac(string secret, string body_)
	{
		return toHexString!(LetterCase.lower)(body_.representation.hmac!SHA256(secret.representation)).idup;
	}
}

unittest // the sha256= HMAC of the body under the secret verifies; another secret or body does not
{
	const signature = "sha256=" ~ hexHmac("s3cret", `{"a":1}`);
	[signatureMatches("s3cret", `{"a":1}`, signature), signatureMatches("other", `{"a":1}`, signature),
		signatureMatches("s3cret", `{"a":2}`, signature)].should.equal([true, false, false]);
}

unittest // a signature without the sha256= prefix, cut short, uppercase or missing is refused
{
	const hex = hexHmac("s3cret", "body");
	[signatureMatches("s3cret", "body", hex), signatureMatches("s3cret", "body", "sha1=" ~ hex),
		signatureMatches("s3cret", "body", "sha256=" ~ hex[0 .. $ - 1]),
		signatureMatches("s3cret", "body", "sha256=" ~ hex ~ "0"),
		signatureMatches("s3cret", "body", "sha256=" ~ hexHmac("s3cret", "body").toUpper),
		signatureMatches("s3cret", "body", "")].should.equal([false, false, false, false, false, false]);
}

unittest // an empty secret verifies nothing, not even the HMAC under the empty key
{
	signatureMatches("", "body", "sha256=" ~ hexHmac("", "body")).should.equal(false);
}

unittest // a UUID delivery id is valid; empty, too long, dotted or dash-ended ones are not
{
	import std.array : replicate;

	[validDeliveryId("72d3162e-cc78-11e3-81ab-4c9367dc0958"), validDeliveryId(""), validDeliveryId("a".replicate(64)),
		validDeliveryId("a.b"), validDeliveryId("abc-"), validDeliveryId("-abc")]
		.should.equal([true, false, false, false, false, false]);
}

unittest // an issues.labeled delivery listed in events starts a run; issues.closed and a bare ping do not
{
	const trigger = webhookSpawner().spec.github;
	[ignoredReason(trigger, "issues", parseJsonString(labeledPayload)),
		ignoredReason(trigger, "issues", parseJsonString(`{"action":"closed"}`)),
		ignoredReason(trigger, "push", parseJsonString(`{}`))].should.equal(["",
		"issues.closed is not one of the spawner's events", "push is not one of the spawner's events"]);
}

unittest // a label filter fires on adding that label, or on another action of an issue carrying it
{
	auto trigger = webhookSpawner().spec.github;
	trigger.label = "agent";
	[ignoredReason(trigger, "issues", parseJsonString(labeledPayload)),
		ignoredReason(trigger, "issues", parseJsonString(`{"action":"labeled","label":{"name":"bug"},
			"issue":{"labels":[{"name":"agent"}]}}`)),
		ignoredReason(trigger, "issues", parseJsonString(`{"action":"opened","issue":{"labels":[{"name":"agent"}]}}`)),
		ignoredReason(trigger, "issues", parseJsonString(`{"action":"opened","issue":{"labels":[]}}`))]
		.should.equal(["", "the label added is not agent", "", "the issue does not carry the label agent"]);
}

unittest // a repository filter matches full_name case-insensitively and ignores other repositories
{
	auto trigger = webhookSpawner().spec.github;
	trigger.repository = "Octo/App";
	trigger.events = ["issues.labeled"];
	[ignoredReason(trigger, "issues", parseJsonString(labeledPayload)),
		ignoredReason(trigger, "issues", parseJsonString(`{"action":"labeled","repository":{"full_name":"evil/app"}}`))]
		.should.equal(["", "repository evil/app is not Octo/App"]);
}

unittest // a labeled payload gives the five issue parameters over the spawner's, which keep their other keys
{
	deliveryParameters(webhookSpawner(), parseJsonString(labeledPayload)).should.equal([
		"tone": "terse", "issue_number": "42", "issue_title": "Crash on start", "issue_body": "It crashes.",
		"issue_url": "https://github.com/octo/app/issues/42", "repo": "octo/app"
	]);
}

unittest // a spawner's git_credential parameters never reach a webhook run, nor does a payload field of that name
{
	import std.algorithm.searching : startsWith;

	auto spawner = webhookSpawner();
	spawner.spec.parameters = ["git_credential": "v1.claims.sig", "git_credential_url": "https://broker"];
	const parameters = deliveryParameters(spawner, parseJsonString(`{"action":"opened",
		"git_credential":"x","git_credential_url":"y","issue":{"git_credential":"z","number":1}}`));
	parameters.keys.canFind!(key => key.startsWith("git_credential")).should.equal(false);
}

unittest // an issue with a null body and no repository gives empty values rather than failing
{
	const parameters = deliveryParameters(webhookSpawner(), parseJsonString(`{"action":"opened","issue":{"body":null}}`));
	[parameters["issue_body"], parameters["issue_number"], parameters["repo"]].should.equal(["", "", ""]);
}

unittest // a delivery's Agent is named after it, owned, labelled with spawner and delivery, and targets the repo
{
	const agent = agentFromDelivery(webhookSpawner(), "72D3162E-cc78-11e3-81ab-4c9367dc0958",
		parseJsonString(labeledPayload));
	// Compared as values: fluent-asserts compares serialized text, whose key order depends on insertion history.
	(agent == parseJsonString(`{
		"apiVersion": "agents.re-cinq.com/v1beta1", "kind": "Agent",
		"metadata": {"name": "fixer-72d3162e-cc78-11e3-81ab-4c9367dc0958", "namespace": "ai-agents",
			"labels": {"agents.re-cinq.com/spawner": "fixer",
				"agents.re-cinq.com/github-delivery": "72D3162E-cc78-11e3-81ab-4c9367dc0958"},
			"ownerReferences": [{"apiVersion": "agents.re-cinq.com/v1beta1", "kind": "AgentSpawner",
				"name": "fixer", "uid": "uid-1", "controller": true, "blockOwnerDeletion": true}]},
		"spec": {"stationRef": "bug-fixer", "targetRepo": "octo/app", "parameters": {"tone": "terse",
			"issue_number": "42", "issue_title": "Crash on start", "issue_body": "It crashes.",
			"issue_url": "https://github.com/octo/app/issues/42", "repo": "octo/app"}}}`)).should.equal(true);
}

unittest // the same delivery always names the same Agent, so a redelivery 409s; another delivery names another
{
	const spawner = webhookSpawner();
	[deliveryAgentName(spawner, "d-1") == deliveryAgentName(spawner, "d-1"),
		deliveryAgentName(spawner, "d-1") == deliveryAgentName(spawner, "d-2")].should.equal([true, false]);
	auto long_ = webhookSpawner();
	long_.metadata.name = "spawner-with-a-very-long-name-that-goes-on-and-on-and-on";
	deliveryAgentName(long_, "72d3162e-cc78-11e3-81ab-4c9367dc0958").length.should.be.lessThan(64);
}
