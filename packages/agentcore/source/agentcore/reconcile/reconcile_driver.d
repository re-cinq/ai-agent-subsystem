module agentcore.reconcile.reconcile_driver;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.station : Station;
import agentcore.reconcile.concurrency : effectiveMaxRuns, oldestRunningRun, stationAtCapacity;
import agentcore.kube.jobs : jobNameFor;
import agentcore.kube.jobspec : buildJob;
import agentcore.kube.jsonbody : statusPatch;
import agentcore.kube.kubeclient : KubeClient, NotFound, PodResult;
import agentcore.reconcile.prune : agentsToPrune;
import agentcore.reconcile.reconcile : ActionKind, coherentExitCode, decide, JobOutcome, JobState;
import agentcore.core.types : Phase;

/// Status reason when the run Job was garbage-collected before the controller could
/// observe its result — the controller was down or backlogged past the Job's
/// TTL-after-finished. The real outcome is unrecoverable, so the run is reported
/// terminal with this reason instead of being left Running forever.
enum runRecordUnavailable = "run record unavailable: Job garbage-collected before its result was observed";

/// Status reason when the Job's result was read but the run pod (and the stdout it
/// captured) was already garbage-collected, so `status.output` could not be
/// recovered. Surfaced instead of a silently empty output.
enum runOutputUnavailable = "run output unavailable: pod garbage-collected";

/// What a single reconcile did that the batch pass (`reconcileAll`) must account for
/// before reconciling the next Agent: whether a new run for this Agent's Station is now
/// in flight, and any run this action preempted. The cache won't reflect either until
/// the status patch round-trips through the informer, so the batch applies them to its
/// working view to keep the Station concurrency count correct within one pass.
struct ReconcileEffect
{
	bool startedRun;
	string preemptedAgent;
}

/**
 * Reconcile one Agent: resolve its refs, decide the next action with the pure
 * `decide()` state machine, then apply the decision through the injected client.
 * `agentImage` is the image whose init container injects the runtime into the
 * run Pod; `now` is the RFC3339 timestamp stamped onto the status (injected so
 * the driver is deterministic and fake-testable). Terminal Agents are a no-op
 * with no I/O. `cached` is the controller's informer view of the namespace's
 * Agents — used for the Station concurrency count and history pruning instead of
 * a fresh LIST per reconcile, so cost stays O(changed) rather than O(all). Returns
 * the `ReconcileEffect` so a batch pass can keep its concurrency count honest.
 */
ReconcileEffect reconcileAgent(KubeClient client, string ns, Agent agent, string agentImage, string now,
	const Agent[] cached)
{
	const phase = agent.status.phase;
	if (phase == Phase.succeeded || phase == Phase.failed)
		return ReconcileEffect.init;

	Station station;
	AgentDefinition definition;
	bool refsResolved = true;
	bool atCapacity = false;
	if (phase == Phase.pending)
	{
		refsResolved = resolveRefs(client, ns, agent, station, definition);
		if (refsResolved)
			atCapacity = stationAtCapacity(cached, agent.spec.stationRef,
				effectiveMaxRuns(station.spec.concurrencyPolicy, station.spec.maxConcurrentRuns));
	}

	JobOutcome outcome;
	bool hasOutcome = false;
	string jobName = agent.status.jobName;
	if (phase == Phase.running)
	{
		// A Running Agent whose status never recorded its jobName (a controller crash
		// between the Running patch and the jobName write) would otherwise observe no
		// outcome and stay Running forever. The Job name is derived from the Agent name,
		// so fall back to it and let observeJob resolve the run or report it terminal.
		if (jobName.length == 0)
			jobName = jobNameFor(agent.metadata.name);
		outcome = observeJob(client, ns, jobName);
		hasOutcome = true;
	}

	const decision = decide(phase, refsResolved, hasOutcome, outcome, atCapacity,
		station.spec.concurrencyPolicy);

	final switch (decision.kind)
	{
	case ActionKind.none:
		return ReconcileEffect.init;
	case ActionKind.startRun:
		client.createJob(ns, buildJob(agent, station, definition, agentImage));
		client.patchAgentStatus(ns, agent.metadata.name,
			statusPatch(decision, jobNameFor(agent.metadata.name), now, agent.metadata.resourceVersion));
		return ReconcileEffect(true);
	case ActionKind.replaceRun:
		const preempted = oldestRunningRun(cached, agent.spec.stationRef);
		client.deleteAgent(ns, preempted, resourceVersionByName(cached, preempted));
		client.createJob(ns, buildJob(agent, station, definition, agentImage));
		client.patchAgentStatus(ns, agent.metadata.name,
			statusPatch(decision, jobNameFor(agent.metadata.name), now, agent.metadata.resourceVersion));
		return ReconcileEffect(true, preempted);
	case ActionKind.failMissingRef:
		client.patchAgentStatus(ns, agent.metadata.name,
			statusPatch(decision, "", now, agent.metadata.resourceVersion));
		return ReconcileEffect.init;
	case ActionKind.complete:
		client.patchAgentStatus(ns, agent.metadata.name,
			statusPatch(decision, jobName, now, agent.metadata.resourceVersion));
		pruneHistory(client, ns, agent.spec.stationRef, cached);
		return ReconcileEffect.init;
	}
}

/// The `resourceVersion` of the cached Agent named `name`, or "" if it is not in the
/// cache — used to send a delete precondition so a stale-cache delete of an Agent that
/// has since changed is rejected rather than removing the newer object.
private string resourceVersionByName(const Agent[] cached, string name) @safe
{
	foreach (agent; cached)
		if (agent.metadata.name == name)
			return agent.metadata.resourceVersion;
	return "";
}

/// Observe the run Job: its terminal/running state, enriched on a terminal
/// transition with the run pod's real values. The TTL-after-finished GC can delete
/// the Job (cascading to its pod) before the controller observes the result if the
/// controller was down or backlogged. A GC'd Job is reported terminal with a clear
/// reason — never re-thrown, which would leave the Agent stuck Running.
private JobOutcome observeJob(KubeClient client, string ns, string jobName)
{
	JobOutcome outcome;
	try
		outcome = client.jobOutcome(ns, jobName);
	catch (NotFound)
		return JobOutcome(JobState.failed, 0, runRecordUnavailable, "");
	if (outcome.state != JobState.running)
		enrichFromPod(client, ns, jobName, outcome);
	return outcome;
}

/// On a terminal Job, replace the placeholder exit code / output the Job
/// conditions carry with the run pod's real values — the `agent` container's exit
/// code and its captured stdout — so `status.exitCode` / `status.output` reflect
/// what actually happened. A pod that has already been GC'd can't be read back, so
/// the outcome records why the output is missing instead of leaving it silently
/// empty (a Job-level failure reason already present is kept).
private void enrichFromPod(KubeClient client, string ns, string jobName, ref JobOutcome outcome)
{
	try
	{
		const podName = client.podNameForJob(ns, jobName);
		if (podName.length == 0)
			return markOutputUnavailable(outcome);
		const pod = client.podResult(ns, podName);
		outcome.exitCode = coherentExitCode(outcome.state, pod.exitCode);
		outcome.output = pod.log;
	}
	catch (Exception)
	{
		// The pod was GC'd between reads, or the log fetch failed: enrichment is
		// best-effort, so degrade to the Job-level outcome instead of re-throwing —
		// which would propagate up and leave the Agent stuck Running forever.
		markOutputUnavailable(outcome);
	}
}

/// Record that the run pod's output couldn't be read back (it was GC'd), keeping any
/// Job-level failure reason already present, and keep the exit code coherent with the
/// Job state so a failed run never reports the placeholder 0.
private void markOutputUnavailable(ref JobOutcome outcome)
{
	if (outcome.reason.length == 0)
		outcome.reason = runOutputUnavailable;
	outcome.exitCode = coherentExitCode(outcome.state, outcome.exitCode);
}

private bool resolveRefs(KubeClient client, string ns, Agent agent, ref Station station,
	ref AgentDefinition definition)
{
	try
	{
		station = client.getStation(ns, agent.spec.stationRef);
		definition = client.getAgentDefinition(ns, station.spec.agentDefRef);
		return true;
	}
	catch (NotFound)
		return false;
}

private void pruneHistory(KubeClient client, string ns, string stationRef, const Agent[] cached)
{
	Station station;
	try
		station = client.getStation(ns, stationRef);
	catch (NotFound)
		return;

	foreach (name; agentsToPrune(cached, stationRef, station.spec.successfulRunsHistoryLimit,
			station.spec.failedRunsHistoryLimit))
		client.deleteAgent(ns, name, resourceVersionByName(cached, name));
}

version (unittest)
{
	import std.exception : enforce;
	import fluent.asserts;
	import vibe.data.json : Json, parseJsonString;
	import agentcore.crds.enums : ConcurrencyPolicy;
	import agentcore.reconcile.reconcile : JobState;

	private final class FakeKubeClient : KubeClient
	{
		Station station;
		AgentDefinition definition;
		bool stationMissing;
		JobOutcome outcome;
		bool jobMissing;
		string podNameValue;
		PodResult podResultValue;
		bool podReadThrows; /// simulate the pod being GC'd between podNameForJob and podResult

		Json[] createdJobs;
		Json[] statusPatches;
		string[] patchedNames;
		string[] deletedAgents;
		string[] deletedVersions;

		override Station getStation(string ns, string name)
		{
			enforce(!stationMissing, new NotFound("station " ~ name ~ " not found"));
			return station;
		}

		override AgentDefinition getAgentDefinition(string ns, string name)
		{
			return definition;
		}

		override void createJob(string ns, Json job)
		{
			createdJobs ~= job;
		}

		override JobOutcome jobOutcome(string ns, string jobName)
		{
			enforce(!jobMissing, new NotFound("Job " ~ jobName ~ " not found"));
			return outcome;
		}

		override void patchAgentStatus(string ns, string name, Json patch)
		{
			patchedNames ~= name;
			statusPatches ~= patch;
		}

		override void deleteAgent(string ns, string name, string resourceVersion = "")
		{
			deletedAgents ~= name;
			deletedVersions ~= resourceVersion;
		}

		override string podNameForJob(string ns, string jobName)
		{
			return podNameValue;
		}

		override PodResult podResult(string ns, string podName)
		{
			enforce(!podReadThrows, new NotFound("pod " ~ podName ~ " not found"));
			return podResultValue;
		}
	}

	private Agent pendingAgent(string name, string stationRef)
	{
		Agent agent;
		agent.metadata.name = name;
		agent.spec.stationRef = stationRef;
		agent.status.phase = Phase.pending;
		return agent;
	}
}

unittest
{
	// Pending + refs resolved -> Job created and status patched to Running.
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.template_ = parseJsonString(
		`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
	client.definition.spec.model = "claude-sonnet-4-6";
	client.definition.spec.prompt = "Fix it";

	reconcileAgent(client, "ai-agents", pendingAgent("run-1", "stn"), "img", "2026-06-22T12:00:00Z", null);

	client.createdJobs.length.should.equal(1);
	client.patchedNames.should.equal(["run-1"]);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Running");
	client.statusPatches[0]["status"]["jobName"].get!string.should.equal("agent-job-run-1");
	client.statusPatches[0]["status"]["startedAt"].get!string.should.equal("2026-06-22T12:00:00Z");
}

unittest
{
	// The Agent's resourceVersion flows into the status patch as an optimistic-
	// concurrency precondition, so two reconcilers racing off different snapshots
	// can't lost-update each other (the stale write 409s).
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.template_ = parseJsonString(
		`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
	client.definition.spec.model = "claude-sonnet-4-6";
	client.definition.spec.prompt = "Fix it";

	auto agent = pendingAgent("run-1", "stn");
	agent.metadata.resourceVersion = "4242";
	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["metadata"]["resourceVersion"].get!string.should.equal("4242");
}

unittest
{
	// Pending + missing Station -> Failed status, no Job.
	auto client = new FakeKubeClient;
	client.stationMissing = true;

	reconcileAgent(client, "ai-agents", pendingAgent("run-2", "gone"), "img", "2026-06-22T12:00:00Z", null);

	client.createdJobs.length.should.equal(0);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].get!string.should
		.equal("Station or AgentDefinition not found");
}

unittest
{
	// Pending + Station already at maxConcurrentRuns -> wait: no Job, no patch.
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.maxConcurrentRuns = 1;
	client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent"}]}}`);

	Agent active; // one run already in flight for this Station
	active.metadata.name = "run-active";
	active.spec.stationRef = "stn";
	active.status.phase = Phase.running;

	reconcileAgent(client, "ai-agents", pendingAgent("run-waiting", "stn"), "img", "now", [active]);

	client.createdJobs.length.should.equal(0);
	client.statusPatches.length.should.equal(0);
}

unittest
{
	// Pending + Station at capacity with concurrencyPolicy Replace -> preempt the
	// oldest Running run (delete it, cascading to its Job) and start the new one.
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.concurrencyPolicy = ConcurrencyPolicy.replace;
	client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent"}]}}`);

	Agent running; // the in-flight run Replace should cancel
	running.metadata.name = "run-old";
	running.metadata.resourceVersion = "rv-old";
	running.spec.stationRef = "stn";
	running.status.phase = Phase.running;
	running.status.startedAt = "2026-06-22T10:00:00Z";

	reconcileAgent(client, "ai-agents", pendingAgent("run-new", "stn"), "img",
		"2026-06-22T12:00:00Z", [running]);

	client.deletedAgents.should.equal(["run-old"]);
	// The preemption carries the victim's resourceVersion as a delete precondition.
	client.deletedVersions.should.equal(["rv-old"]);
	client.createdJobs.length.should.equal(1);
	client.patchedNames.should.equal(["run-new"]);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Running");
	client.statusPatches[0]["status"]["jobName"].get!string.should.equal("agent-job-run-new");
}

unittest
{
	// Running + Job succeeded -> Succeeded; status enriched from the run pod
	// (output = pod log, exitCode = the agent container's real code), history pruned.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.succeeded);
	client.podNameValue = "agent-job-run-3-abc";
	client.podResultValue = PodResult(0, "the wrapped event log");
	client.station.metadata.name = "stn";
	client.station.spec.successfulRunsHistoryLimit = 0; // prune the whole succeeded bucket

	Agent old;
	old.metadata.name = "old-success";
	old.metadata.resourceVersion = "rv-old-success";
	old.spec.stationRef = "stn";
	old.status.phase = Phase.succeeded;
	old.status.completedAt = "2026-06-22T01:00:00Z";

	// Another Station's history must survive stn's limit-0 prune (#87).
	Agent foreign;
	foreign.metadata.name = "other-station-success";
	foreign.spec.stationRef = "other-stn";
	foreign.status.phase = Phase.succeeded;
	foreign.status.completedAt = "2026-06-22T01:00:00Z";

	Agent agent;
	agent.metadata.name = "run-3";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-3";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", [old, foreign]);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Succeeded");
	client.statusPatches[0]["status"]["output"].get!string.should.equal("the wrapped event log");
	client.statusPatches[0]["status"]["exitCode"].get!long.should.equal(0);
	client.deletedAgents.should.equal(["old-success"]);
	// The pruning delete carries the Agent's resourceVersion as a precondition.
	client.deletedVersions.should.equal(["rv-old-success"]);
}

unittest
{
	// Running + Job failed -> Failed status carries the pod's real exit code + log.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.failed, 0, "BackoffLimitExceeded", "");
	client.podNameValue = "agent-job-run-6-xyz";
	client.podResultValue = PodResult(42, "boom in the log");
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-6";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-6";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["exitCode"].get!long.should.equal(42);
	client.statusPatches[0]["status"]["output"].get!string.should.equal("boom in the log");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal("BackoffLimitExceeded");
}

unittest
{
	// Running + Job succeeded but the run pod was GC'd before readback -> still
	// Succeeded, but status carries a clear reason instead of a silently empty output.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.succeeded);
	client.podNameValue = ""; // pod garbage-collected
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-7";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-7";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Succeeded");
	client.statusPatches[0]["status"]["output"].get!string.should.equal("");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal(runOutputUnavailable);
}

unittest
{
	// Running + Job failed, but the pod was GC'd between podNameForJob and podResult
	// (podResult throws) -> still reported terminal Failed (never left stuck Running),
	// keeping the Job-level reason and a non-zero exit code.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.failed, 1, "BackoffLimitExceeded", "");
	client.podNameValue = "agent-job-run-9-xyz";
	client.podReadThrows = true;
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-9";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-9";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal("BackoffLimitExceeded");
	client.statusPatches[0]["status"]["exitCode"].get!long.should.equal(1);
}

unittest
{
	// Running + Job failed but the pod's container exit code reads back as 0 (a GC
	// race leaves it unpopulated) -> status must not contradict itself with "Failed,
	// exitCode 0"; report a non-zero code while keeping the captured log.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.failed, 1, "DeadlineExceeded", "");
	client.podNameValue = "agent-job-run-10-xyz";
	client.podResultValue = PodResult(0, "partial log");
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-10";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-10";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["exitCode"].get!long.should.equal(1);
	client.statusPatches[0]["status"]["output"].get!string.should.equal("partial log");
}

unittest
{
	// Running + Job itself GC'd (controller backlogged past ttlSecondsAfterFinished)
	// -> reported terminal Failed with a clear reason, not left stuck Running.
	auto client = new FakeKubeClient;
	client.jobMissing = true;
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-8";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-8";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal(runRecordUnavailable);
}

unittest
{
	// Running + Job still running -> no-op, no patch.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.running);

	Agent agent;
	agent.metadata.name = "run-4";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-4";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches.length.should.equal(0);
	client.createdJobs.length.should.equal(0);
}

unittest
{
	// #125: a Running Agent whose status never recorded its jobName (a controller crash
	// between the Running patch and the jobName write) must not stay Running forever. The
	// Job name is derived from the Agent name, so the run is observed under it and repaired;
	// here the Job is gone, so the Agent completes Failed instead of stalling with no patch.
	auto client = new FakeKubeClient;
	client.jobMissing = true;
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-11";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches.length.should.equal(1);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal(runRecordUnavailable);
	// The recovered (derived) Job name is written into the terminal record, so the run
	// no longer ends with a permanently empty jobName.
	client.statusPatches[0]["status"]["jobName"].get!string.should.equal("agent-job-run-11");
}
