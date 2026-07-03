module agentcore.kube.jsonbody;

import vibe.data.json;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.station : Station;
import agentcore.crds.schema : wire, optional;
import agentcore.crds.serialization : fromJson;
import agentcore.reconcile.reconcile : ActionKind, Decision, JobOutcome, JobState;

/// The merge-patch body the controller PATCHes onto an Agent's `/status`
/// subresource after a reconcile `Decision`. Only the changed fields are
/// included, per JSON merge-patch semantics. The caller supplies `jobName` (the
/// Job it created) and `timestamp` (an RFC3339 "now") so this stays pure: it
/// stamps `startedAt` on a start and `completedAt` on a terminal transition.
Json statusPatch(Decision decision, string jobName, string timestamp, string resourceVersion = "")
{
	Json status = Json.emptyObject;
	status["phase"] = cast(string) decision.phase;

	final switch (decision.kind)
	{
	case ActionKind.startRun:
	case ActionKind.replaceRun:
		status["jobName"] = jobName;
		status["startedAt"] = timestamp;
		break;
	case ActionKind.failMissingRef:
		status["failureReason"] = decision.failureReason;
		status["completedAt"] = timestamp;
		break;
	case ActionKind.complete:
		status["exitCode"] = decision.exitCode;
		status["output"] = decision.output;
		if (decision.failureReason.length)
			status["failureReason"] = decision.failureReason;
		status["completedAt"] = timestamp;
		break;
	case ActionKind.none:
		break;
	}

	Json patch = Json.emptyObject;
	patch["status"] = status;
	// Include the read's resourceVersion so the API server rejects (409) a write
	// computed from a stale snapshot instead of clobbering a newer update.
	if (resourceVersion.length)
	{
		Json meta = Json.emptyObject;
		meta["resourceVersion"] = resourceVersion;
		patch["metadata"] = meta;
	}
	return patch;
}

/// Parse a Kubernetes Agent object into the typed struct. Unknown/missing fields
/// fall back to their defaults rather than throwing — the API server is trusted
/// to return well-formed JSON, but optional fields are genuinely optional (that
/// leniency is `CrdPolicy` + `@optional`, see agentcore.crds.serialization).
Agent parseAgent(Json value)
{
	return fromJson!Agent(value);
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

private struct AgentListMeta
{
	@optional string resourceVersion;
	@optional @wire("continue") string continueToken;
}

/// Parse one page of a Kubernetes AgentList: its `.items` and the list-level
/// `metadata.resourceVersion` / `metadata.continue`. Items are parsed one at a
/// time so a single malformed Agent (e.g. a type-mismatched field) is skipped
/// rather than throwing away the whole page — otherwise one bad object stalls
/// the poll's full-LIST safety net for every Agent.
AgentListPage parseAgentListPage(Json value)
{
	AgentListMeta metadata;
	if (auto meta = "metadata" in value)
		if (meta.type == Json.Type.object)
			metadata = fromJson!AgentListMeta(*meta);

	Agent[] items;
	if (auto rawItems = "items" in value)
		if (rawItems.type == Json.Type.array)
			foreach (item; rawItems.get!(Json[]))
				try
					items ~= parseAgent(item);
				catch (Exception)
				{
				}

	return AgentListPage(items, metadata.resourceVersion, metadata.continueToken);
}

/// Parse a Kubernetes Station object into the typed struct.
Station parseStation(Json value)
{
	return fromJson!Station(value);
}

/// Parse a Kubernetes AgentDefinition object into the typed recipe.
AgentDefinition parseAgentDefinition(Json value)
{
	return fromJson!AgentDefinition(value);
}

/// Derive a `JobOutcome` from a Kubernetes Job object. A `Complete` condition is
/// success, a `Failed` condition carries its reason; otherwise the Job is still
/// running. `exitCode` and `output` are not in the Job status (they live in the
/// pod) — enriching them from pod logs is a later refinement.
JobOutcome parseJobOutcome(Json value)
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

private string conditionReason(Json condition)
{
	const reason = childString(condition, "reason");
	const message = childString(condition, "message");
	if (reason.length && message.length)
		return reason ~ ": " ~ message;
	return reason.length ? reason : message;
}

private string childString(Json object, string key)
{
	if (object.type == Json.Type.object)
		if (auto found = key in object)
			if (found.type == Json.Type.string)
				return found.get!string;
	return "";
}

private long childInt(Json object, string key, long fallback)
{
	if (object.type == Json.Type.object)
		if (auto found = key in object)
			if (found.type == Json.Type.int_)
				return found.get!long;
	return fallback;
}

private Json childObject(Json object, string key)
{
	if (object.type == Json.Type.object)
		if (auto found = key in object)
			return *found;
	return Json.emptyObject;
}

private Json[] childArray(Json object, string key)
{
	if (object.type == Json.Type.object)
		if (auto found = key in object)
			if (found.type == Json.Type.array)
				return found.get!(Json[]);
	return null;
}

version (unittest)
{
	import fluent.asserts;
	import agentcore.core.types : Phase;
	import agentcore.crds.enums : ConcurrencyPolicy, McpTransport, PermissionMode,
		SelectEvent, SinkType;
	import agentcore.crds.env_var : EnvVar;
	import agentcore.crds.secret_ref : SecretRef;
}

unittest
{
	auto patch = statusPatch(Decision(ActionKind.startRun, Phase.running), "agent-job-x",
		"2026-06-22T12:00:00Z");
	patch["status"]["phase"].get!string.should.equal("Running");
	patch["status"]["jobName"].get!string.should.equal("agent-job-x");
	patch["status"]["startedAt"].get!string.should.equal("2026-06-22T12:00:00Z");
}

unittest
{
	// A resourceVersion is carried as an optimistic-concurrency precondition, so a
	// write computed from a stale read is rejected (409) instead of clobbering a newer
	// update. With none, no metadata is sent (an unconditional patch).
	auto guarded = statusPatch(Decision(ActionKind.startRun, Phase.running), "agent-job-x",
		"2026-06-22T12:00:00Z", "12345");
	guarded["metadata"]["resourceVersion"].get!string.should.equal("12345");

	auto plain = statusPatch(Decision(ActionKind.startRun, Phase.running), "agent-job-x",
		"2026-06-22T12:00:00Z");
	(("metadata" in plain) is null).should.equal(true);
}

unittest
{
	auto patch = statusPatch(Decision(ActionKind.failMissingRef, Phase.failed, 0,
			"Station or AgentDefinition not found"), "", "2026-06-22T12:00:00Z");
	patch["status"]["phase"].get!string.should.equal("Failed");
	patch["status"]["failureReason"].get!string.should.equal("Station or AgentDefinition not found");
	patch["status"]["completedAt"].get!string.should.equal("2026-06-22T12:00:00Z");
}

unittest
{
	auto ok = statusPatch(Decision(ActionKind.complete, Phase.succeeded, 0, "", "all good"),
		"agent-job-x", "2026-06-22T13:00:00Z");
	ok["status"]["phase"].get!string.should.equal("Succeeded");
	ok["status"]["output"].get!string.should.equal("all good");
	ok["status"]["exitCode"].get!long.should.equal(0);

	auto bad = statusPatch(Decision(ActionKind.complete, Phase.failed, 1, "boom", ""),
		"agent-job-x", "2026-06-22T13:00:00Z");
	bad["status"]["phase"].get!string.should.equal("Failed");
	bad["status"]["failureReason"].get!string.should.equal("boom");
	bad["status"]["exitCode"].get!long.should.equal(1);
}

unittest
{
	auto agent = parseAgent(parseJsonString(`{
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
	parseAgent(parseJsonString(`{"metadata":{"name":"fresh"},"spec":{"stationRef":"s"}}`))
		.status.phase.should.equal(Phase.pending);

	// A list page parses each item plus the resourceVersion and continue token.
	auto page = parseAgentListPage(parseJsonString(`{"metadata":{"resourceVersion":"7","continue":"tok"},`
			~ `"items":[{"metadata":{"name":"a"}},{"metadata":{"name":"b"}}]}`));
	page.items.length.should.equal(2);
	page.resourceVersion.should.equal("7");
	page.continueToken.should.equal("tok");

	// The last page carries no continue token.
	parseAgentListPage(parseJsonString(`{"metadata":{"resourceVersion":"9"},"items":[]}`))
		.continueToken.should.equal("");

	// One malformed item (exitCode is int; here a string) is skipped rather than
	// throwing away the whole page, so a single bad Agent can't stall the poll's
	// full-LIST safety net for every other Agent.
	auto resilient = parseAgentListPage(parseJsonString(`{"metadata":{"resourceVersion":"11"},`
			~ `"items":[{"metadata":{"name":"ok-1"}},`
			~ `{"metadata":{"name":"bad"},"status":{"exitCode":"boom"}},`
			~ `{"metadata":{"name":"ok-2"}}]}`));
	resilient.items.length.should.equal(2);
	resilient.resourceVersion.should.equal("11");
	resilient.items[0].metadata.name.should.equal("ok-1");
	resilient.items[1].metadata.name.should.equal("ok-2");
}

unittest
{
	auto station = parseStation(parseJsonString(`{
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
	station.spec.template_["spec"]["containers"].get!(Json[]).length.should.equal(0);
}

unittest
{
	// concurrencyPolicy defaults to Allow when absent or unrecognised.
	parseStation(parseJsonString(`{"metadata":{"name":"stn"},"spec":{"template":{}}}`))
		.spec.concurrencyPolicy.should.equal(ConcurrencyPolicy.allow);
}

unittest
{
	auto definition = parseAgentDefinition(parseJsonString(`{
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
	// Every recipe field survives parsing into the typed AgentDefinition — env, secrets,
	// select, sinks (incl. headers_secret), mcp_servers, tool_config. Guards the seam
	// where a hand-maintained field list silently dropped the recipe's secrets and
	// produced runs without credentials (#85). (mcp_servers/tool_config parse but are
	// not yet injected into the run env — see the CRD reference.)
	auto definition = parseAgentDefinition(parseJsonString(`{
		"metadata":{"name":"bug-fixer"},
		"spec":{"model":"claude-sonnet-4-6","prompt":"Fix {t}",
			"resources":{
				"env":[{"name":"LOG_LEVEL","value":"debug"}],
				"secrets":[{"name":"ANTHROPIC_API_KEY","ref":"ANTHROPIC_API_KEY"}],
				"mcp_servers":[{"name":"gh","transport":"http","url":"http://mcp"}]},
			"output":{
				"select":[{"event":"result"},{"event":"tool_call","tool":"Bash"}],
				"sinks":[{"type":"http","url":"http://c","headers_secret":"SINK_HEADERS"}]},
			"tool_config":{"sandbox":true}}}`));
	definition.spec.resources.env.should.equal([EnvVar("LOG_LEVEL", "debug")]);
	definition.spec.resources.secrets.should.equal([
		SecretRef("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY")
	]);
	definition.spec.resources.mcpServers[0].transport.should.equal(McpTransport.http);
	definition.spec.output.select.length.should.equal(2);
	definition.spec.output.select[0].event.should.equal(SelectEvent.result);
	definition.spec.output.select[1].tool.should.equal("Bash");
	definition.spec.output.sinks[0].headersSecret.should.equal("SINK_HEADERS");
	definition.spec.toolConfig["sandbox"].get!bool.should.equal(true);
}

unittest
{
	// An unrecognised enum string keeps the field's default instead of throwing:
	// a typo'd sink type degrades to stdout, permission_mode stays bypass.
	auto definition = parseAgentDefinition(parseJsonString(`{
		"metadata":{"name":"typo"},
		"spec":{"permission_mode":"noneuchmode",
			"output":{"sinks":[{"type":"htpp","url":"http://c"}]}}}`));
	definition.spec.permissionMode.should.equal(PermissionMode.bypass);
	definition.spec.output.sinks[0].type.should.equal(SinkType.stdout);
}

unittest
{
	parseJobOutcome(parseJsonString(`{"status":{"conditions":[{"type":"Complete","status":"True"}]}}`))
		.state.should.equal(JobState.succeeded);

	auto failed = parseJobOutcome(parseJsonString(
			`{"status":{"conditions":[{"type":"Failed","status":"True","reason":"DeadlineExceeded","message":"too slow"}]}}`));
	failed.state.should.equal(JobState.failed);
	failed.reason.should.equal("DeadlineExceeded: too slow");

	parseJobOutcome(parseJsonString(`{"status":{"succeeded":1}}`)).state.should.equal(JobState.succeeded);
	parseJobOutcome(parseJsonString(`{"status":{}}`)).state.should.equal(JobState.running);
}
