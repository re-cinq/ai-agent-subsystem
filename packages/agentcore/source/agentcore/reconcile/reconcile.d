module agentcore.reconcile.reconcile;

import agentcore.batch.provider : BatchPoll, BatchState;
import agentcore.core.types : Phase;
import agentcore.crds.enums : BatchTimeoutAction, ConcurrencyPolicy;

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
	string sessionId;
}

/// Reconcile the Job-level state with a pod-reported exit code so `status` never
/// contradicts itself. A failed run must report a non-zero code even when the pod's
/// container status reads back as 0 (a GC race can leave it unpopulated), and a
/// succeeded run always reports 0.
int coherentExitCode(JobState state, int podExitCode) @safe pure nothrow
{
	final switch (state)
	{
	case JobState.succeeded:
		return 0;
	case JobState.failed:
		return podExitCode != 0 ? podExitCode : 1;
	case JobState.running:
		return podExitCode;
	}
}

/// What the controller should do for an Agent, decided purely from inputs.
enum ActionKind
{
	none, /// nothing to do (still running, or already terminal)
	startRun, /// create the Job and move to Running
	replaceRun, /// preempt the Station's oldest run (Replace policy), then start this one
	replaceWithBatch, /// preempt the Station's oldest run (Replace policy), then submit this batch
	failMissingRef, /// a referenced Station/AgentDefinition is missing, or its spec cannot run
	complete, /// move to a terminal phase from the Job outcome
	submitBatch, /// submit the prompt to the vendor's batch API and move to Running
	pollBatch, /// poll the in-flight batch for its result
	batchTimeoutFail, /// cancel the timed-out batch and move to Failed
	batchFallbackStart, /// cancel the timed-out batch and run the definition as a Job instead
	batchFallbackWait, /// cancel the timed-out batch and wait for a Station slot for its Job
}

/// Whether `kind` follows a batch timeout, so the in-flight batch must be cancelled first.
bool cancelsBatch(ActionKind kind) @safe pure nothrow
{
	return kind == ActionKind.batchTimeoutFail || kind == ActionKind.batchFallbackStart
		|| kind == ActionKind.batchFallbackWait;
}

/// The batch-execution facts of an Agent `decide()` needs: whether its definition runs as a
/// batch, the provider batch id recorded in its status, and whether it fell back to a Job.
struct BatchRun
{
	bool batch;
	string batchId;
	bool fallback;
	bool awaitingJob; /// fell back, but its Job is not created yet
}

struct Decision
{
	ActionKind kind;
	Phase phase;
	int exitCode;
	string failureReason;
	string output;
	string sessionId;
}

/**
 * The pure reconcile state machine. All I/O — resolving refs, creating Jobs,
 * patching status, pruning history, counting the Station's active runs — is
 * performed by the caller based on the returned Decision. `atCapacity` is true
 * when the Station is already at its effective concurrent-run limit; what a Pending
 * Agent does then depends on `policy`: Allow/Forbid wait, Replace preempts the
 * Station's oldest run and starts (`ActionKind.replaceRun`). A non-empty
 * `specViolation` (the resolved definition cannot run as configured) fails it.
 * `batchRun` routes a batch-executed Agent: Pending submits its batch, Running polls it
 * until it falls back to a Job, after which the Job branches apply.
 */
Decision decide(Phase current, bool refsResolved, bool hasOutcome, JobOutcome outcome,
	bool atCapacity = false, ConcurrencyPolicy policy = ConcurrencyPolicy.allow,
	string specViolation = "", BatchRun batchRun = BatchRun.init) @safe pure
{
	final switch (current)
	{
	case Phase.pending:
		if (!refsResolved)
			return missingRef;
		if (specViolation.length > 0)
			return Decision(ActionKind.failMissingRef, Phase.failed, 0, specViolation);
		if (atCapacity && policy != ConcurrencyPolicy.replace)
			return Decision(ActionKind.none, Phase.pending);
		if (atCapacity)
			return Decision(batchRun.batch ? ActionKind.replaceWithBatch : ActionKind.replaceRun, Phase.running);
		if (batchRun.batch)
			return Decision(ActionKind.submitBatch, Phase.running);
		return Decision(ActionKind.startRun, Phase.running);
	case Phase.running:
		if (!refsResolved)
			return missingRef;
		if (batchRun.awaitingJob)
			return atCapacity ? Decision(ActionKind.none, Phase.running) : Decision(ActionKind.startRun, Phase.running);
		if (batchRun.batchId.length > 0 && !batchRun.fallback)
			return Decision(ActionKind.pollBatch, Phase.running);
		if (!hasOutcome || outcome.state == JobState.running)
			return Decision(ActionKind.none, Phase.running);
		if (outcome.state == JobState.succeeded)
			return Decision(ActionKind.complete, Phase.succeeded, outcome.exitCode, outcome.reason,
					outcome.output, outcome.sessionId);
		return Decision(ActionKind.complete, Phase.failed, outcome.exitCode, outcome.reason,
				outcome.output, outcome.sessionId);
	case Phase.succeeded:
	case Phase.failed:
		return Decision(ActionKind.none, current);
	}
}

private enum missingRef = Decision(ActionKind.failMissingRef, Phase.failed, 0,
		"Station or AgentDefinition not found");

/// Status reason when a batch outlived `batch.timeoutMinutes` and `onTimeout` is fail.
enum batchTimedOutReason = "batch timed out";

/// The decision a batch poll leads to: a finished batch completes the Agent with `output`
/// (the poll's translated CLI lines), carrying the vendor's error as the failure reason,
/// even when it has also `timedOut` — a result in hand wins. A pending batch keeps waiting
/// until it times out; its fallback Job waits while the Station is `atCapacity`.
Decision batchPolled(const BatchPoll poll, string output, bool timedOut, BatchTimeoutAction onTimeout,
	bool atCapacity) @safe pure
{
	final switch (poll.state)
	{
	case BatchState.pending:
		if (!timedOut)
			return Decision(ActionKind.none, Phase.running);
		if (onTimeout == BatchTimeoutAction.fail)
			return Decision(ActionKind.batchTimeoutFail, Phase.failed, 1, batchTimedOutReason);
		return Decision(atCapacity ? ActionKind.batchFallbackWait : ActionKind.batchFallbackStart,
			Phase.running);
	case BatchState.succeeded:
		return Decision(ActionKind.complete, Phase.succeeded, 0, "", output);
	case BatchState.failed:
		return Decision(ActionKind.complete, Phase.failed, 1, poll.error, output);
	}
}

/// Whether `timeoutMinutes` have passed between the RFC3339 `startedAt` and `now`.
bool batchTimedOut(string startedAt, string now, int timeoutMinutes) @safe
{
	import core.time : minutes;
	import std.datetime.systime : SysTime;

	return SysTime.fromISOExtString(now) - SysTime.fromISOExtString(startedAt) >= timeoutMinutes.minutes;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	// Exit code stays coherent with the Job state: a failed run never reports 0 (a
	// GC race can leave the pod's container exit code unset), a succeeded run is 0.
	coherentExitCode(JobState.failed, 0).should.equal(1);
	coherentExitCode(JobState.failed, 42).should.equal(42);
	coherentExitCode(JobState.succeeded, 0).should.equal(0);
	coherentExitCode(JobState.succeeded, 9).should.equal(0);
}

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

@safe unittest // a spec violation fails a Pending Agent with it as the reason, even at capacity
{
	decide(Phase.pending, true, false, JobOutcome.init, true, ConcurrencyPolicy.allow, "bad spec")
		.should.equal(Decision(ActionKind.failMissingRef, Phase.failed, 0, "bad spec"));
}

@safe unittest
{
	JobOutcome no;
	// At capacity: Allow and Forbid both wait (stay Pending)...
	decide(Phase.pending, true, false, no, true, ConcurrencyPolicy.allow)
		.kind.should.equal(ActionKind.none);
	decide(Phase.pending, true, false, no, true, ConcurrencyPolicy.forbid)
		.kind.should.equal(ActionKind.none);

	// ...while Replace preempts the oldest run and starts (-> Running).
	const replacing = decide(Phase.pending, true, false, no, true, ConcurrencyPolicy.replace);
	replacing.kind.should.equal(ActionKind.replaceRun);
	replacing.phase.should.equal(Phase.running);

	// Replace with room (not at capacity) just starts normally.
	decide(Phase.pending, true, false, no, false, ConcurrencyPolicy.replace)
		.kind.should.equal(ActionKind.startRun);
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

@safe unittest // a finished Job's session id is carried onto the completion decision
{
	decide(Phase.running, true, true, JobOutcome(JobState.succeeded, 0, "", "out", "sess-1"))
		.should.equal(Decision(ActionKind.complete, Phase.succeeded, 0, "", "out", "sess-1"));
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

@safe unittest // pending batch agent without a batchId decides submitBatch to Running
{
	decide(Phase.pending, true, false, JobOutcome.init, false, ConcurrencyPolicy.allow, "",
		BatchRun(true)).should.equal(Decision(ActionKind.submitBatch, Phase.running));
}

@safe unittest // running batch agent with a batchId and no fallback decides pollBatch
{
	decide(Phase.running, true, false, JobOutcome.init, false, ConcurrencyPolicy.allow, "",
		BatchRun(true, "msgbatch_1")).should.equal(Decision(ActionKind.pollBatch, Phase.running));
}

@safe unittest // running batch agent in fallback with a succeeded Job completes from the Job outcome
{
	decide(Phase.running, true, true, JobOutcome(JobState.succeeded, 0, "", "out"), false,
		ConcurrencyPolicy.allow, "", BatchRun(true, "msgbatch_1", true))
		.should.equal(Decision(ActionKind.complete, Phase.succeeded, 0, "", "out"));
}

@safe unittest // pending batch agent at Station capacity waits Pending
{
	decide(Phase.pending, true, false, JobOutcome.init, true, ConcurrencyPolicy.allow, "",
		BatchRun(true)).should.equal(Decision(ActionKind.none, Phase.pending));
}

unittest // pending batch agent at capacity under Replace preempts the oldest run and submits its batch
{
	decide(Phase.pending, true, false, JobOutcome.init, true, ConcurrencyPolicy.replace, "",
		BatchRun(true)).should.equal(Decision(ActionKind.replaceWithBatch, Phase.running));
}
