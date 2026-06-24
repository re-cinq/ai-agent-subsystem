module agentcore.kube.jsonbody;

import std.json : JSONType, JSONValue;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.enums : ConcurrencyPolicy, PermissionMode, SinkType;
import agentcore.crds.output_sink : OutputSink;
import agentcore.crds.repo_ref : RepoRef;
import agentcore.crds.station : Station;
import agentcore.reconcile.reconcile : ActionKind, Decision, JobOutcome, JobState;
import agentcore.core.types : Phase;

/// The merge-patch body the controller PATCHes onto an Agent's `/status`
/// subresource after a reconcile `Decision`. Only the changed fields are
/// included, per JSON merge-patch semantics. The caller supplies `jobName` (the
/// Job it created) and `timestamp` (an RFC3339 "now") so this stays pure: it
/// stamps `startedAt` on a start and `completedAt` on a terminal transition.
JSONValue statusPatch(Decision decision, string jobName, string timestamp, string resourceVersion = "")
{
	JSONValue[string] status;
	status["phase"] = JSONValue(cast(string) decision.phase);

	final switch (decision.kind)
	{
	case ActionKind.startRun:
	case ActionKind.replaceRun:
		status["jobName"] = JSONValue(jobName);
		status["startedAt"] = JSONValue(timestamp);
		break;
	case ActionKind.failMissingRef:
		status["failureReason"] = JSONValue(decision.failureReason);
		status["completedAt"] = JSONValue(timestamp);
		break;
	case ActionKind.complete:
		status["exitCode"] = JSONValue(decision.exitCode);
		status["output"] = JSONValue(decision.output);
		if (decision.failureReason.length)
			status["failureReason"] = JSONValue(decision.failureReason);
		status["completedAt"] = JSONValue(timestamp);
		break;
	case ActionKind.none:
		break;
	}

	JSONValue[string] patch;
	patch["status"] = JSONValue(status);
	// Include the read's resourceVersion so the API server rejects (409) a write
	// computed from a stale snapshot instead of clobbering a newer update.
	if (resourceVersion.length)
		patch["metadata"] = JSONValue(["resourceVersion": JSONValue(resourceVersion)]);
	return JSONValue(patch);
}

/// Parse a Kubernetes Agent object into the typed struct. Unknown/missing fields
/// fall back to their defaults rather than throwing — the API server is trusted
/// to return well-formed JSON, but optional fields are genuinely optional.
Agent parseAgent(JSONValue value)
{
	auto meta = childObject(value, "metadata");
	auto spec = childObject(value, "spec");
	auto status = childObject(value, "status");

	Agent agent;
	agent.metadata.name = childString(meta, "name");
	agent.metadata.namespace = childString(meta, "namespace");
	agent.metadata.uid = childString(meta, "uid");
	agent.metadata.resourceVersion = childString(meta, "resourceVersion");
	agent.spec.stationRef = childString(spec, "stationRef");
	agent.spec.taskId = childString(spec, "taskId");
	agent.spec.targetRepo = childString(spec, "targetRepo");
	agent.spec.branch = childString(spec, "branch");
	agent.spec.parameters = childStringMap(spec, "parameters");
	agent.status.phase = toPhase(childString(status, "phase"));
	agent.status.jobName = childString(status, "jobName");
	agent.status.startedAt = childString(status, "startedAt");
	agent.status.completedAt = childString(status, "completedAt");
	return agent;
}

/// One page of a Kubernetes AgentList: the typed items plus the list's
/// `metadata.resourceVersion` (where a watch resumes from) and `metadata.continue`
/// (the token for the next page, empty on the last page). Capturing these is what
/// lets the controller paginate and resume the watch instead of re-listing from 0.
struct AgentListPage
{
	Agent[] items;
	string resourceVersion;
	string continueToken;
}

/// Parse one page of a Kubernetes AgentList: its `.items` and the list-level
/// `metadata.resourceVersion` / `metadata.continue`.
AgentListPage parseAgentListPage(JSONValue value)
{
	AgentListPage page;
	foreach (item; childArray(value, "items"))
		page.items ~= parseAgent(item);
	auto meta = childObject(value, "metadata");
	page.resourceVersion = childString(meta, "resourceVersion");
	page.continueToken = childString(meta, "continue");
	return page;
}

/// Parse a Kubernetes Station object into the typed struct.
Station parseStation(JSONValue value)
{
	auto meta = childObject(value, "metadata");
	auto spec = childObject(value, "spec");

	Station station;
	station.metadata.name = childString(meta, "name");
	station.metadata.namespace = childString(meta, "namespace");
	station.spec.agentDefRef = childString(spec, "agentDefRef");
	station.spec.deadlineMinutes = cast(int) childInt(spec, "deadlineMinutes", 30);
	station.spec.successfulRunsHistoryLimit = cast(int) childInt(spec, "successfulRunsHistoryLimit", 3);
	station.spec.failedRunsHistoryLimit = cast(int) childInt(spec, "failedRunsHistoryLimit", 3);
	station.spec.maxConcurrentRuns = cast(int) childInt(spec, "maxConcurrentRuns", 0);
	station.spec.concurrencyPolicy = toConcurrencyPolicy(childString(spec, "concurrencyPolicy"));
	station.spec.template_ = childObject(spec, "template");
	return station;
}

/// Parse a Kubernetes AgentDefinition object into the typed recipe.
AgentDefinition parseAgentDefinition(JSONValue value)
{
	auto meta = childObject(value, "metadata");
	auto spec = childObject(value, "spec");

	AgentDefinition definition;
	definition.metadata.name = childString(meta, "name");
	definition.metadata.namespace = childString(meta, "namespace");
	definition.spec.description = childString(spec, "description");
	definition.spec.model = childString(spec, "model");
	definition.spec.prompt = childString(spec, "prompt");
	definition.spec.allowedTools = childStringArray(spec, "allowed_tools");
	definition.spec.disallowedTools = childStringArray(spec, "disallowed_tools");
	definition.spec.permissionMode = toPermissionMode(childString(spec, "permission_mode"));
	definition.spec.maxTurns = cast(int) childInt(spec, "max_turns", 0);
	definition.spec.resources.repos = parseRepos(childObject(spec, "resources"));
	definition.spec.output.sinks = parseSinks(childObject(spec, "output"));
	return definition;
}

/// Derive a `JobOutcome` from a Kubernetes Job object. A `Complete` condition is
/// success, a `Failed` condition carries its reason; otherwise the Job is still
/// running. `exitCode` and `output` are not in the Job status (they live in the
/// pod) — enriching them from pod logs is a later refinement.
JobOutcome parseJobOutcome(JSONValue value)
{
	auto status = childObject(value, "status");
	foreach (condition; childArray(status, "conditions"))
	{
		if (childString(condition, "status") != "True")
			continue;
		const type = childString(condition, "type");
		if (type == "Complete")
			return JobOutcome(JobState.succeeded, 0, "", "");
		if (type == "Failed")
			return JobOutcome(JobState.failed, 1, conditionReason(condition), "");
	}
	if (childInt(status, "succeeded", 0) > 0)
		return JobOutcome(JobState.succeeded, 0, "", "");
	if (childInt(status, "failed", 0) > 0)
		return JobOutcome(JobState.failed, 1, "Job failed", "");
	return JobOutcome(JobState.running);
}

private RepoRef[] parseRepos(JSONValue resources)
{
	RepoRef[] repos;
	foreach (entry; childArray(resources, "repos"))
	{
		RepoRef repo;
		repo.name = childString(entry, "name");
		repo.url = childString(entry, "url");
		repo.ref_ = childString(entry, "ref");
		repo.path = childString(entry, "path");
		repo.tokenSecret = childString(entry, "token_secret");
		if (repo.name.length && repo.url.length)
			repos ~= repo;
	}
	return repos;
}

private OutputSink[] parseSinks(JSONValue output)
{
	OutputSink[] sinks;
	foreach (entry; childArray(output, "sinks"))
	{
		OutputSink sink;
		sink.type = toSinkType(childString(entry, "type"));
		sink.url = childString(entry, "url");
		sink.path = childString(entry, "path");
		sink.headersSecret = childString(entry, "headers_secret");
		sinks ~= sink;
	}
	return sinks;
}

private string conditionReason(JSONValue condition)
{
	const reason = childString(condition, "reason");
	const message = childString(condition, "message");
	if (reason.length && message.length)
		return reason ~ ": " ~ message;
	return reason.length ? reason : message;
}

private Phase toPhase(string phase)
{
	switch (phase)
	{
	case "Running":
		return Phase.running;
	case "Succeeded":
		return Phase.succeeded;
	case "Failed":
		return Phase.failed;
	default:
		return Phase.pending;
	}
}

private PermissionMode toPermissionMode(string mode)
{
	return mode == "auto" ? PermissionMode.auto_ : PermissionMode.bypass;
}

private ConcurrencyPolicy toConcurrencyPolicy(string policy)
{
	switch (policy)
	{
	case "Forbid":
		return ConcurrencyPolicy.forbid;
	case "Replace":
		return ConcurrencyPolicy.replace;
	default:
		return ConcurrencyPolicy.allow;
	}
}

private SinkType toSinkType(string type)
{
	switch (type)
	{
	case "http":
		return SinkType.http;
	case "file":
		return SinkType.file;
	default:
		return SinkType.stdout;
	}
}

private string childString(JSONValue object, string key)
{
	if (object.type != JSONType.object)
		return "";
	if (auto found = key in object.object)
		return found.type == JSONType.string ? found.str : "";
	return "";
}

private long childInt(JSONValue object, string key, long fallback)
{
	if (object.type != JSONType.object)
		return fallback;
	if (auto found = key in object.object)
		return found.type == JSONType.integer ? found.integer : fallback;
	return fallback;
}

private JSONValue childObject(JSONValue object, string key)
{
	if (object.type == JSONType.object)
		if (auto found = key in object.object)
			return *found;
	return JSONValue(cast(JSONValue[string]) null);
}

private JSONValue[] childArray(JSONValue object, string key)
{
	if (object.type == JSONType.object)
		if (auto found = key in object.object)
			if (found.type == JSONType.array)
				return found.array;
	return null;
}

private string[] childStringArray(JSONValue object, string key)
{
	string[] result;
	foreach (entry; childArray(object, key))
		if (entry.type == JSONType.string)
			result ~= entry.str;
	return result;
}

private string[string] childStringMap(JSONValue object, string key)
{
	string[string] result;
	auto map = childObject(object, key);
	if (map.type == JSONType.object)
		foreach (entryKey, entryValue; map.object)
			if (entryValue.type == JSONType.string)
				result[entryKey] = entryValue.str;
	return result;
}

version (unittest) import fluent.asserts;

unittest
{
	auto patch = statusPatch(Decision(ActionKind.startRun, Phase.running), "agent-job-x",
		"2026-06-22T12:00:00Z");
	patch["status"]["phase"].str.should.equal("Running");
	patch["status"]["jobName"].str.should.equal("agent-job-x");
	patch["status"]["startedAt"].str.should.equal("2026-06-22T12:00:00Z");
}

unittest
{
	// A resourceVersion is carried as an optimistic-concurrency precondition, so a
	// write computed from a stale read is rejected (409) instead of clobbering a newer
	// update. With none, no metadata is sent (an unconditional patch).
	auto guarded = statusPatch(Decision(ActionKind.startRun, Phase.running), "agent-job-x",
		"2026-06-22T12:00:00Z", "12345");
	guarded["metadata"]["resourceVersion"].str.should.equal("12345");

	auto plain = statusPatch(Decision(ActionKind.startRun, Phase.running), "agent-job-x",
		"2026-06-22T12:00:00Z");
	(("metadata" in plain.object) is null).should.equal(true);
}

unittest
{
	auto patch = statusPatch(Decision(ActionKind.failMissingRef, Phase.failed, 0,
			"Station or AgentDefinition not found"), "", "2026-06-22T12:00:00Z");
	patch["status"]["phase"].str.should.equal("Failed");
	patch["status"]["failureReason"].str.should.equal("Station or AgentDefinition not found");
	patch["status"]["completedAt"].str.should.equal("2026-06-22T12:00:00Z");
}

unittest
{
	auto ok = statusPatch(Decision(ActionKind.complete, Phase.succeeded, 0, "", "all good"),
		"agent-job-x", "2026-06-22T13:00:00Z");
	ok["status"]["phase"].str.should.equal("Succeeded");
	ok["status"]["output"].str.should.equal("all good");
	ok["status"]["exitCode"].integer.should.equal(0);

	auto bad = statusPatch(Decision(ActionKind.complete, Phase.failed, 1, "boom", ""),
		"agent-job-x", "2026-06-22T13:00:00Z");
	bad["status"]["phase"].str.should.equal("Failed");
	bad["status"]["failureReason"].str.should.equal("boom");
	bad["status"]["exitCode"].integer.should.equal(1);
}

version (unittest) import std.json : parseJSON;

unittest
{
	auto agent = parseAgent(parseJSON(`{
		"metadata":{"name":"run-1","namespace":"ai-agents","uid":"u1"},
		"spec":{"stationRef":"stn","taskId":"T1","targetRepo":"o/r","branch":"b","parameters":{"ticket":"E-1"}},
		"status":{"phase":"Running","jobName":"agent-job-run-1","startedAt":"t0"}}`));
	agent.metadata.name.should.equal("run-1");
	agent.metadata.uid.should.equal("u1");
	agent.spec.stationRef.should.equal("stn");
	agent.spec.parameters["ticket"].should.equal("E-1");
	agent.status.phase.should.equal(Phase.running);
	agent.status.jobName.should.equal("agent-job-run-1");
}

unittest
{
	// No status -> phase defaults to Pending.
	parseAgent(parseJSON(`{"metadata":{"name":"fresh"},"spec":{"stationRef":"s"}}`))
		.status.phase.should.equal(Phase.pending);

	// A list page parses each item plus the resourceVersion and continue token.
	auto page = parseAgentListPage(parseJSON(`{"metadata":{"resourceVersion":"7","continue":"tok"},`
			~ `"items":[{"metadata":{"name":"a"}},{"metadata":{"name":"b"}}]}`));
	page.items.length.should.equal(2);
	page.resourceVersion.should.equal("7");
	page.continueToken.should.equal("tok");

	// The last page carries no continue token.
	parseAgentListPage(parseJSON(`{"metadata":{"resourceVersion":"9"},"items":[]}`))
		.continueToken.should.equal("");
}

unittest
{
	auto station = parseStation(parseJSON(`{
		"metadata":{"name":"stn"},
		"spec":{"agentDefRef":"def","deadlineMinutes":45,"successfulRunsHistoryLimit":1,
			"maxConcurrentRuns":2,"concurrencyPolicy":"Replace",
			"template":{"spec":{"containers":[]}}}}`));
	station.spec.agentDefRef.should.equal("def");
	station.spec.deadlineMinutes.should.equal(45);
	station.spec.successfulRunsHistoryLimit.should.equal(1);
	station.spec.failedRunsHistoryLimit.should.equal(3); // default kept when absent
	station.spec.maxConcurrentRuns.should.equal(2);
	station.spec.concurrencyPolicy.should.equal(ConcurrencyPolicy.replace);
	station.spec.template_["spec"]["containers"].array.length.should.equal(0);
}

unittest
{
	// concurrencyPolicy defaults to Allow when absent or unrecognised.
	parseStation(parseJSON(`{"metadata":{"name":"stn"},"spec":{"template":{}}}`))
		.spec.concurrencyPolicy.should.equal(ConcurrencyPolicy.allow);
}

unittest
{
	auto definition = parseAgentDefinition(parseJSON(`{
		"metadata":{"name":"bug-fixer"},
		"spec":{"model":"claude-sonnet-4-6","prompt":"Fix {t}","permission_mode":"auto",
			"allowed_tools":["Read","Edit"],"max_turns":40,
			"resources":{"repos":[{"name":"app","url":"o/app","ref":"main"}]},
			"output":{"sinks":[{"type":"http","url":"http://c"}]}}}`));
	definition.spec.model.should.equal("claude-sonnet-4-6");
	definition.spec.permissionMode.should.equal(PermissionMode.auto_);
	definition.spec.allowedTools.should.equal(["Read", "Edit"]);
	definition.spec.maxTurns.should.equal(40);
	definition.spec.resources.repos.length.should.equal(1);
	definition.spec.resources.repos[0].url.should.equal("o/app");
	definition.spec.output.sinks.length.should.equal(1);
	definition.spec.output.sinks[0].type.should.equal(SinkType.http);
}

unittest
{
	parseJobOutcome(parseJSON(`{"status":{"conditions":[{"type":"Complete","status":"True"}]}}`))
		.state.should.equal(JobState.succeeded);

	auto failed = parseJobOutcome(parseJSON(
			`{"status":{"conditions":[{"type":"Failed","status":"True","reason":"DeadlineExceeded","message":"too slow"}]}}`));
	failed.state.should.equal(JobState.failed);
	failed.reason.should.equal("DeadlineExceeded: too slow");

	parseJobOutcome(parseJSON(`{"status":{"succeeded":1}}`)).state.should.equal(JobState.succeeded);
	parseJobOutcome(parseJSON(`{"status":{}}`)).state.should.equal(JobState.running);
}
