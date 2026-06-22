module agentcore.jsonbody;

import std.json : JSONValue;

import agentcore.reconcile : ActionKind, Decision;

/// The merge-patch body the controller PATCHes onto an Agent's `/status`
/// subresource after a reconcile `Decision`. Only the changed fields are
/// included, per JSON merge-patch semantics. The caller supplies `jobName` (the
/// Job it created) and `timestamp` (an RFC3339 "now") so this stays pure: it
/// stamps `startedAt` on a start and `completedAt` on a terminal transition.
JSONValue statusPatch(Decision decision, string jobName, string timestamp)
{
	JSONValue[string] status;
	status["phase"] = JSONValue(cast(string) decision.phase);

	final switch (decision.kind)
	{
	case ActionKind.startRun:
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

	return JSONValue(["status": JSONValue(status)]);
}

version (unittest) import fluent.asserts;
version (unittest) import agentcore.types : Phase;

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
