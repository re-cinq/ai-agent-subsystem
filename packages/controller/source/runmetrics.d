module runmetrics;

import std.datetime.systime : SysTime;

import agentcore.core.types : Phase;
import agentcore.crds.agent : Agent;
import agentcore.reconcile.reconcile : ActionKind;
import agentcore.reconcile.reconcile_driver : ReconcileEffect;
import metrics : recordRunCompleted, recordRunDuration, recordRunFailure, recordRunQueued;

/// Turn what one reconcile decided into the run metrics: a start records how long
/// the Agent waited since its creation; a terminal transition records the run's
/// phase and exit code, its duration since `startedAt` when it ran at all, and the
/// kind of reason it ended with, if any. A run preempted under the Replace policy is
/// deleted at Running and gets no terminal status, so its only trace is the failure
/// kind recorded here. `now` is the RFC3339 timestamp the status patch carried, so
/// the metric and the status agree to the second.
void recordRunEffect(const Agent agent, const ReconcileEffect effect, string now) nothrow
{
	final switch (effect.decision.kind)
	{
	case ActionKind.none:
		break;
	case ActionKind.startRun:
		recordRunQueued(secondsBetween(agent.metadata.creationTimestamp, now));
		break;
	case ActionKind.replaceRun:
		recordRunQueued(secondsBetween(agent.metadata.creationTimestamp, now));
		recordRunFailure("preempted");
		break;
	case ActionKind.failMissingRef:
		recordRunCompleted(cast(string) effect.decision.phase, effect.decision.exitCode);
		recordRunFailure("missing_ref");
		break;
	case ActionKind.complete:
		recordRunCompleted(cast(string) effect.decision.phase, effect.decision.exitCode);
		recordRunDuration(cast(string) effect.decision.phase, secondsBetween(agent.status.startedAt, now));
		if (effect.decision.failureReason.length)
			recordRunFailure(effect.decision.phase == Phase.failed ? "job_failed" : "output_unavailable");
		break;
	}
}

/// Seconds from one RFC3339 timestamp to another; 0 when either is missing or
/// unreadable, because a dropped sample is better than a crashed reconcile.
double secondsBetween(string from, string until) nothrow
{
	if (from.length == 0 || until.length == 0)
		return 0;
	try
	{
		const elapsed = SysTime.fromISOExtString(until) - SysTime.fromISOExtString(from);
		return elapsed.total!"msecs" / 1000.0;
	}
	catch (Exception)
		return 0;
}

version (unittest) import fluent.asserts;
version (unittest) import metrics : renderMetrics, resetMetrics;
version (unittest) import agentcore.reconcile.reconcile : Decision;

unittest
{
	secondsBetween("2026-10-09T10:00:00Z", "2026-10-09T10:02:30Z").should.equal(150);
	secondsBetween("", "2026-10-09T10:02:30Z").should.equal(0);
	secondsBetween("not a time", "2026-10-09T10:02:30Z").should.equal(0);
}

unittest
{
	resetMetrics();
	Agent agent;
	agent.metadata.name = "run-1";
	agent.metadata.creationTimestamp = "2026-10-09T10:00:00Z";
	agent.status.startedAt = "2026-10-09T10:00:05Z";

	recordRunEffect(agent, ReconcileEffect(true, "", Decision(ActionKind.startRun, Phase.running)),
		"2026-10-09T10:00:05Z");
	recordRunEffect(agent, ReconcileEffect(false, "", Decision(ActionKind.complete, Phase.failed, 1, "boom")),
		"2026-10-09T10:10:05Z");

	const text = renderMetrics();

	text.should.contain("controller_run_queue_seconds_count 1");
	text.should.contain(`controller_run_queue_seconds_bucket{le="8"} 1`);
	text.should.contain(`controller_runs_completed_total{phase="Failed",exit_code="1"} 1`);
	text.should.contain(`controller_run_duration_seconds_sum{phase="Failed"} 600`);
	text.should.contain(`controller_run_failures_total{kind="job_failed"} 1`);
}

unittest
{
	// A missing reference never ran: counted as completed, no duration observed. A
	// preemption leaves no terminal status: counted only as a failure kind.
	resetMetrics();
	Agent agent;
	agent.metadata.creationTimestamp = "2026-10-09T10:00:00Z";

	recordRunEffect(agent, ReconcileEffect(false, "", Decision(ActionKind.failMissingRef, Phase.failed)),
		"2026-10-09T10:00:01Z");
	recordRunEffect(agent, ReconcileEffect(true, "old-run", Decision(ActionKind.replaceRun, Phase.running)),
		"2026-10-09T10:00:02Z");

	const text = renderMetrics();

	text.should.contain(`controller_runs_completed_total{phase="Failed",exit_code="0"} 1`);
	text.should.not.contain("controller_run_duration_seconds_count");
	text.should.contain(`controller_run_failures_total{kind="missing_ref"} 1`);
	text.should.contain(`controller_run_failures_total{kind="preempted"} 1`);
	text.should.contain("controller_run_queue_seconds_count 1");
}
