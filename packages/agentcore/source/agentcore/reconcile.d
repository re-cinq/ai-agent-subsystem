module agentcore.reconcile;

import agentcore.types : Phase;

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
 * patching status, pruning history — is performed by the caller based on the
 * returned Decision.
 */
Decision decide(Phase current, bool refsResolved, bool hasOutcome, JobOutcome outcome) @safe pure
{
	final switch (current)
	{
	case Phase.pending:
		if (!refsResolved)
			return Decision(ActionKind.failMissingRef, Phase.failed, 0,
				"Station or AgentDefinition not found");
		return Decision(ActionKind.startRun, Phase.running);
	case Phase.running:
		if (!hasOutcome || outcome.state == JobState.running)
			return Decision(ActionKind.none, Phase.running);
		if (outcome.state == JobState.succeeded)
			return Decision(ActionKind.complete, Phase.succeeded, outcome.exitCode, "", outcome
					.output);
		return Decision(ActionKind.complete, Phase.failed, outcome.exitCode, outcome.reason, outcome
				.output);
	case Phase.succeeded:
	case Phase.failed:
		return Decision(ActionKind.none, current);
	}
}

@safe unittest
{
	JobOutcome no;
	// Pending + refs resolved -> start the run.
	const start = decide(Phase.pending, true, false, no);
	assert(start.kind == ActionKind.startRun && start.phase == Phase.running);

	// Pending + missing refs -> fail with a reason.
	const missing = decide(Phase.pending, false, false, no);
	assert(missing.kind == ActionKind.failMissingRef && missing.phase == Phase.failed);
	assert(missing.failureReason.length > 0);
}

@safe unittest
{
	// Running with no outcome yet, or a still-running Job -> do nothing.
	JobOutcome none;
	assert(decide(Phase.running, true, false, none).kind == ActionKind.none);
	assert(decide(Phase.running, true, true, JobOutcome(JobState.running)).kind == ActionKind.none);
}

@safe unittest
{
	// Running + succeeded / failed -> complete with the carried details.
	const ok = decide(Phase.running, true, true, JobOutcome(JobState.succeeded, 0, "", "all good"));
	assert(ok.kind == ActionKind.complete && ok.phase == Phase.succeeded && ok.output == "all good");

	const bad = decide(Phase.running, true, true, JobOutcome(JobState.failed, 1, "boom", ""));
	assert(bad.kind == ActionKind.complete && bad.phase == Phase.failed);
	assert(bad.exitCode == 1 && bad.failureReason == "boom");
}

@safe unittest
{
	// Terminal phases are no-ops.
	JobOutcome no;
	assert(decide(Phase.succeeded, true, true, no).kind == ActionKind.none);
	assert(decide(Phase.failed, true, true, no).kind == ActionKind.none);
}
