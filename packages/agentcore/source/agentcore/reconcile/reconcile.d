module agentcore.reconcile.reconcile;

import agentcore.core.types : Phase;

/// Observed state of the Job backing a running Agent.
enum JobState
{
	running,
	succeeded,
	failed,
}

struct JobOutcome
{
	JobState state;
	int exitCode;
	string reason;
	string output;
}

/// What the controller should do for an Agent, decided purely from inputs.
enum ActionKind
{
	none, /// nothing to do (still running, or already terminal)
	startRun, /// create the Job and move to Running
	failMissingRef, /// a referenced Station/AgentDefinition is missing
	complete, /// move to a terminal phase from the Job outcome
}

struct Decision
{
	ActionKind kind;
	Phase phase;
	int exitCode;
	string failureReason;
	string output;
}

/**
 * The pure reconcile state machine. All I/O — resolving refs, creating Jobs,
 * patching status, pruning history, counting the Station's active runs — is
 * performed by the caller based on the returned Decision. `atCapacity` is true
 * when the Station is already at its `maxConcurrentRuns`, in which case a Pending
 * Agent waits rather than starting.
 */
Decision decide(Phase current, bool refsResolved, bool hasOutcome, JobOutcome outcome,
	bool atCapacity = false) @safe pure
{
	final switch (current)
	{
	case Phase.pending:
		if (!refsResolved)
			return Decision(ActionKind.failMissingRef, Phase.failed, 0,
				"Station or AgentDefinition not found");
		if (atCapacity)
			return Decision(ActionKind.none, Phase.pending);
		return Decision(ActionKind.startRun, Phase.running);
	case Phase.running:
		if (!hasOutcome || outcome.state == JobState.running)
			return Decision(ActionKind.none, Phase.running);
		if (outcome.state == JobState.succeeded)
			return Decision(ActionKind.complete, Phase.succeeded, outcome.exitCode, outcome.reason,
					outcome.output);
		return Decision(ActionKind.complete, Phase.failed, outcome.exitCode, outcome.reason, outcome
				.output);
	case Phase.succeeded:
	case Phase.failed:
		return Decision(ActionKind.none, current);
	}
}

version (unittest) import fluent.asserts;

@safe unittest
{
	JobOutcome no;
	// Pending + refs resolved -> start the run.
	const start = decide(Phase.pending, true, false, no);
	start.kind.should.equal(ActionKind.startRun);
	start.phase.should.equal(Phase.running);

	// Pending + missing refs -> fail with a reason.
	const missing = decide(Phase.pending, false, false, no);
	missing.kind.should.equal(ActionKind.failMissingRef);
	missing.phase.should.equal(Phase.failed);
	missing.failureReason.length.should.be.greaterThan(0);

	// Pending + refs resolved but the Station is at capacity -> wait (stay Pending).
	const waiting = decide(Phase.pending, true, false, no, true);
	waiting.kind.should.equal(ActionKind.none);
	waiting.phase.should.equal(Phase.pending);
}

@safe unittest
{
	// Running with no outcome yet, or a still-running Job -> do nothing.
	JobOutcome none;
	decide(Phase.running, true, false, none).kind.should.equal(ActionKind.none);
	decide(Phase.running, true, true, JobOutcome(JobState.running)).kind.should.equal(ActionKind.none);
}

@safe unittest
{
	// Running + succeeded / failed -> complete with the carried details.
	const ok = decide(Phase.running, true, true, JobOutcome(JobState.succeeded, 0, "", "all good"));
	ok.kind.should.equal(ActionKind.complete);
	ok.phase.should.equal(Phase.succeeded);
	ok.output.should.equal("all good");

	const bad = decide(Phase.running, true, true, JobOutcome(JobState.failed, 1, "boom", ""));
	bad.kind.should.equal(ActionKind.complete);
	bad.phase.should.equal(Phase.failed);
	bad.exitCode.should.equal(1);
	bad.failureReason.should.equal("boom");
}

@safe unittest
{
	// A succeeded run whose outcome carries a reason (e.g. its output couldn't be
	// recovered) surfaces it as failureReason, so the empty output is never silent.
	const degraded = decide(Phase.running, true, true,
		JobOutcome(JobState.succeeded, 0, "run output unavailable: pod garbage-collected", ""));
	degraded.phase.should.equal(Phase.succeeded);
	degraded.failureReason.should.equal("run output unavailable: pod garbage-collected");
}

@safe unittest
{
	// Terminal phases are no-ops.
	JobOutcome no;
	decide(Phase.succeeded, true, true, no).kind.should.equal(ActionKind.none);
	decide(Phase.failed, true, true, no).kind.should.equal(ActionKind.none);
}
