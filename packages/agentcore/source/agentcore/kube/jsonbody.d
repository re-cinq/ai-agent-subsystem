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
	case ActionKind.batchFallbackWait:
		status["batchFallback"] = true;
		break;
	case ActionKind.batchFallbackStart:
		status["batchFallback"] = true;
		status["jobName"] = jobName;
		status["startedAt"] = timestamp;
		break;
	case ActionKind.failMissingRef:
		status["failureReason"] = decision.failureReason;
		status["completedAt"] = timestamp;
		break;
	case ActionKind.complete:
	case ActionKind.batchTimeoutFail:
		// Record the Job the run used, so a run whose jobName was recovered from the
		// derived name (an Agent left Running with an empty status.jobName) still ends
		// with a complete terminal record instead of a permanently empty jobName column.
		if (jobName.length)
			status["jobName"] = jobName;
		status["exitCode"] = decision.exitCode;
		status["output"] = decision.output;
		if (decision.failureReason.length)
			status["failureReason"] = decision.failureReason;
		if (decision.sessionId.length)
			status["sessionId"] = decision.sessionId;
		if (decision.prUrl.length)
			status["prUrl"] = decision.prUrl;
		status["completedAt"] = timestamp;
		break;
	case ActionKind.none:
	case ActionKind.submitBatch:
	case ActionKind.replaceWithBatch:
	case ActionKind.pollBatch:
		break;
	}

	return withPrecondition(status, resourceVersion);
}

/// The status patch recording a submitted batch: Running, its provider batch id and
/// provider name, and `startedAt` — the clock `batch.timeoutMinutes` counts from.
Json batchSubmittedPatch(string batchId, string provider, string timestamp, string resourceVersion = "")
{
	auto status = Json([
		"phase": Json("Running"),
		"batchId": Json(batchId),
		"batchProvider": Json(provider),
		"startedAt": Json(timestamp),
	]);
	return withPrecondition(status, resourceVersion);
}

/// The JSON patch (RFC 6902) adding `finalizer` to an Agent holding `current`. It appends
/// instead of replacing the list, so a finalizer another writer added meanwhile survives.
Json addFinalizerPatch(const string[] current, string finalizer)
{
	if (current.length == 0)
		return Json([jsonPatchOp("add", "/metadata/finalizers", serializeToJson([finalizer]))]);
	return Json([jsonPatchOp("add", "/metadata/finalizers/-", Json(finalizer))]);
}

/// The JSON patch (RFC 6902) removing `finalizer` from an Agent holding `current`. The
/// `test` op makes the API server reject (422) the patch when the list shifted since the
/// read, instead of removing someone else's finalizer. Empty when `finalizer` is absent.
Json removeFinalizerPatch(const string[] current, string finalizer)
{
	import std.algorithm.searching : countUntil;
	import std.conv : to;

	const index = current.countUntil(finalizer);
	if (index < 0)
		return Json.emptyArray;
	const path = "/metadata/finalizers/" ~ index.to!string;
	return Json([jsonPatchOp("test", path, Json(finalizer)), jsonPatchOp("remove", path)]);
}

/// The JSON patch (RFC 6902) giving an Agent holding `current` labels every `wanted`
/// label. Each differing label is added alone, so labels other writers set survive. An
/// Agent with no labels gets the whole map, guarded by a `test` on `resourceVersion` so
/// the API server rejects (422) the patch instead of replacing labels added since the
/// read. Empty when every wanted label already holds its value.
Json labelsPatch(const string[string] current, const string[string] wanted, string resourceVersion)
{
	import std.algorithm.sorting : sort;
	import std.array : replace;

	if (current.length == 0)
		return Json([jsonPatchOp("test", "/metadata/resourceVersion", Json(resourceVersion)),
			jsonPatchOp("add", "/metadata/labels", serializeToJson(wanted))]);
	Json[] operations;
	foreach (key; wanted.keys.sort)
	{
		const held = key in current;
		if (held is null || *held != wanted[key])
			operations ~= jsonPatchOp("add", "/metadata/labels/" ~ key.replace("~", "~0").replace("/", "~1"),
				Json(wanted[key]));
	}
	return Json(operations);
}

private Json jsonPatchOp(string op, string path, Json value = Json.undefined)
{
	auto operation = Json.emptyObject;
	operation["op"] = op;
	operation["path"] = path;
	if (value.type != Json.Type.undefined)
		operation["value"] = value;
	return operation;
}

/// The status patch counting failed provider cleanups; sent without a precondition, since
/// it follows a status patch in the same reconcile that already moved the resourceVersion.
Json batchCleanupAttemptsPatch(int attempts)
{
	return Json(["status": Json(["batchCleanupAttempts": Json(attempts)])]);
}

private Json withPrecondition(Json status, string resourceVersion)
{
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
	import agentcore.crds.enums : BatchTimeoutAction, ConcurrencyPolicy, Execution, McpTransport, PermissionMode,
		SelectEvent, SinkType;
	import agentcore.crds.env_var : EnvVar;
	import agentcore.crds.secret_ref : SecretRef;
	import agentcore.crds.repo_ref : RepoRef;
	import agentcore.crds.conversation_ref : ConversationRef;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.crds.output_selector : OutputSelector;
	import agentcore.crds.output_watch : OutputWatch;
	import agentcore.crds.watch_upload : WatchUpload;
	import agentcore.crds.agent_definition_spec : BatchSpec;
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

unittest // a completed run carries its session id, and one without a session omits the field
{
	auto withSession = statusPatch(Decision(ActionKind.complete, Phase.succeeded, 0, "", "out", "sess-1"),
		"agent-job-x", "2026-06-22T13:00:00Z");
	withSession["status"]["sessionId"].get!string.should.equal("sess-1");

	auto without = statusPatch(Decision(ActionKind.complete, Phase.succeeded, 0, "", "out"),
		"agent-job-x", "2026-06-22T13:00:00Z");
	(("sessionId" in without["status"]) is null).should.equal(true);
}

unittest // a completed run carries the pull request it opened, and one that opened none omits the field
{
	auto opened = statusPatch(Decision(ActionKind.complete, Phase.succeeded, 0, "", "out", "",
		"https://github.com/o/app/pull/7"), "agent-job-x", "2026-06-22T13:00:00Z");
	auto none = statusPatch(Decision(ActionKind.complete, Phase.succeeded, 0, "", "out"),
		"agent-job-x", "2026-06-22T13:00:00Z");

	[opened["status"]["prUrl"].get!string, ("prUrl" in none["status"]) is null ? "absent" : "present"]
		.should.equal(["https://github.com/o/app/pull/7", "absent"]);
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
	// A run's own model is read off its spec; a spec without one leaves it empty.
	parseAgent(parseJsonString(`{"metadata":{"name":"r"},"spec":{"stationRef":"s","model":"gemini-2.5-pro"}}`))
		.spec.model.should.equal("gemini-2.5-pro");
	parseAgent(parseJsonString(`{"metadata":{"name":"r"},"spec":{"stationRef":"s"}}`))
		.spec.model.should.equal("");
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

unittest // every per-run wiring field of an Agent survives parsing into the typed Agent
{
	auto agent = parseAgent(parseJsonString(`{
		"metadata":{"name":"run-1"},
		"spec":{"stationRef":"stn",
			"repos":[{"name":"app","url":"o/app","ref":"main","token_secret":"RUN_TOKEN"}],
			"conversation":{"id":"c1","pin":"p1"},
			"output":{"sinks":[{"type":"http","url":"http://c","headers_secret":"SINK_HEADERS"}],
				"select":[{"event":"result"}],
				"watch":[{"event":"report","path":"r.md","upload":{"url":"http://u","headers_secret":"UP"}}]},
			"secrets":[{"name":"RUN_TOKEN","ref":"run-1-token"}],
			"env":[{"name":"TICKET","value":"E-1"}]}}`));
	agent.spec.repos.should.equal([RepoRef("app", "o/app", "main", "", "RUN_TOKEN")]);
	agent.spec.conversation.should.equal(ConversationRef("", "c1", "p1"));
	agent.spec.output.sinks.should.equal([OutputSink(SinkType.http, "http://c", "SINK_HEADERS")]);
	agent.spec.output.select.should.equal([OutputSelector(SelectEvent.result)]);
	agent.spec.output.watch.should.equal([OutputWatch("report", "r.md", WatchUpload("http://u", "UP"))]);
	agent.spec.secrets.should.equal([SecretRef("RUN_TOKEN", "run-1-token")]);
	agent.spec.env.should.equal([EnvVar("TICKET", "E-1")]);
}

unittest
{
	// Every recipe field survives parsing into the typed AgentDefinition — env, secrets,
	// select, sinks (incl. headers_secret), mcp_servers, tool_config. Guards the seam
	// where a hand-maintained field list silently dropped the recipe's secrets and
	// produced runs without credentials (#85). (mcp_servers is now injected — the Claude
	// adapter renders it into `--mcp-config` and runEnv injects its headers_secret as a
	// run env var; see the CRD reference.)
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
	// a typo'd sink type degrades to stdout, a typo'd permission_mode to the secure
	// default (auto) — never opening up to bypass.
	auto definition = parseAgentDefinition(parseJsonString(`{
		"metadata":{"name":"typo"},
		"spec":{"permission_mode":"noneuchmode",
			"output":{"sinks":[{"type":"htpp","url":"http://c"}]}}}`));
	definition.spec.permissionMode.should.equal(PermissionMode.auto_);
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

unittest // definition without execution parses as interactive with batch defaults
{
	auto definition = parseAgentDefinition(parseJsonString(`{"metadata":{"name":"d"},"spec":{"prompt":"p"}}`));
	definition.spec.execution.should.equal(Execution.interactive);
	definition.spec.batch.should.equal(BatchSpec(1440, BatchTimeoutAction.fail, 16_000));
}

unittest // definition with execution batch, batch fallback after 60 minutes and maxTokens 2048 parses all three
{
	auto definition = parseAgentDefinition(parseJsonString(`{"metadata":{"name":"d"},"spec":{"prompt":"p",
		"execution":"batch","batch":{"timeoutMinutes":60,"onTimeout":"fallback","maxTokens":2048}}}`));
	definition.spec.execution.should.equal(Execution.batch);
	definition.spec.batch.should.equal(BatchSpec(60, BatchTimeoutAction.fallback, 2048));
}

unittest // agent status with batch fields parses batchId, batchProvider and batchFallback
{
	auto agent = parseAgent(parseJsonString(`{"metadata":{"name":"r"},"spec":{"stationRef":"s"},
		"status":{"phase":"Running","batchId":"msgbatch_1","batchProvider":"anthropic","batchFallback":true}}`));
	[agent.status.batchId, agent.status.batchProvider].should.equal(["msgbatch_1", "anthropic"]);
	agent.status.batchFallback.should.equal(true);
}

unittest // adding a finalizer to an Agent without finalizers creates the list holding it
{
	addFinalizerPatch([], "agents.re-cinq.com/batch-cleanup").should.equal(parseJsonString(
		`[{"op":"add","path":"/metadata/finalizers","value":["agents.re-cinq.com/batch-cleanup"]}]`));
}

unittest // adding a finalizer to an Agent with other/keep appends it, leaving other/keep in place
{
	addFinalizerPatch(["other/keep"], "agents.re-cinq.com/batch-cleanup").should.equal(parseJsonString(
		`[{"op":"add","path":"/metadata/finalizers/-","value":"agents.re-cinq.com/batch-cleanup"}]`));
}

unittest // labelling an Agent without labels sets the map, guarded by its resourceVersion
{
	labelsPatch(null, ["agents.re-cinq.com/station": "stn"], "41").should.equal(parseJsonString(`[
		{"op":"test","path":"/metadata/resourceVersion","value":"41"},
		{"op":"add","path":"/metadata/labels","value":{"agents.re-cinq.com/station":"stn"}}]`));
}

unittest // labelling an Agent with team=a and a stale station adds only the differing labels
{
	labelsPatch(["team": "a", "agents.re-cinq.com/station": "old"],
		["agents.re-cinq.com/station": "stn", "agents.re-cinq.com/agent-definition": "def"], "41")
		.should.equal(parseJsonString(`[
			{"op":"add","path":"/metadata/labels/agents.re-cinq.com~1agent-definition","value":"def"},
			{"op":"add","path":"/metadata/labels/agents.re-cinq.com~1station","value":"stn"}]`));
}

unittest // labelling an Agent that already holds every label patches nothing
{
	labelsPatch(["agents.re-cinq.com/station": "stn"], ["agents.re-cinq.com/station": "stn"], "41")
		.length.should.equal(0);
}

unittest // removing the finalizer at index 1 tests it is still there, then removes index 1
{
	removeFinalizerPatch(["other/keep", "agents.re-cinq.com/batch-cleanup"], "agents.re-cinq.com/batch-cleanup")
		.should.equal(parseJsonString(`[
			{"op":"test","path":"/metadata/finalizers/1","value":"agents.re-cinq.com/batch-cleanup"},
			{"op":"remove","path":"/metadata/finalizers/1"}]`));
}
