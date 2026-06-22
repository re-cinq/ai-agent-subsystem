module agentcore.reconcile_driver;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.station : Station;
import agentcore.concurrency : stationAtCapacity;
import agentcore.jobs : jobNameFor;
import agentcore.jobspec : buildJob;
import agentcore.jsonbody : statusPatch;
import agentcore.kubeclient : KubeClient, NotFound, PodResult;
import agentcore.prune : agentsToPrune;
import agentcore.reconcile : ActionKind, decide, JobOutcome, JobState;
import agentcore.types : Phase;

/**
 * Reconcile one Agent: resolve its refs, decide the next action with the pure
 * `decide()` state machine, then apply the decision through the injected client.
 * `agentImage` is the image whose init container injects the runtime into the
 * run Pod; `now` is the RFC3339 timestamp stamped onto the status (injected so
 * the driver is deterministic and fake-testable). Terminal Agents are a no-op
 * with no I/O.
 */
void reconcileAgent(KubeClient client, string ns, Agent agent, string agentImage, string now)
{
	const phase = agent.status.phase;
	if (phase == Phase.succeeded || phase == Phase.failed)
		return;

	Station station;
	AgentDefinition definition;
	bool refsResolved = true;
	bool atCapacity = false;
	if (phase == Phase.pending)
	{
		refsResolved = resolveRefs(client, ns, agent, station, definition);
		if (refsResolved)
			atCapacity = stationAtCapacity(client.listAgents(ns), agent.spec.stationRef,
				station.spec.maxConcurrentRuns);
	}

	JobOutcome outcome;
	bool hasOutcome = false;
	if (phase == Phase.running && agent.status.jobName.length)
	{
		outcome = client.jobOutcome(ns, agent.status.jobName);
		hasOutcome = true;
		if (outcome.state != JobState.running)
			enrichFromPod(client, ns, agent.status.jobName, outcome);
	}

	const decision = decide(phase, refsResolved, hasOutcome, outcome, atCapacity);

	final switch (decision.kind)
	{
	case ActionKind.none:
		return;
	case ActionKind.startRun:
		client.createJob(ns, buildJob(agent, station, definition, agentImage));
		client.patchAgentStatus(ns, agent.metadata.name,
			statusPatch(decision, jobNameFor(agent.metadata.name), now));
		return;
	case ActionKind.failMissingRef:
		client.patchAgentStatus(ns, agent.metadata.name, statusPatch(decision, "", now));
		return;
	case ActionKind.complete:
		client.patchAgentStatus(ns, agent.metadata.name,
			statusPatch(decision, agent.status.jobName, now));
		pruneHistory(client, ns, agent.spec.stationRef);
		return;
	}
}

/// On a terminal Job, replace the placeholder exit code / output the Job
/// conditions carry with the run pod's real values — the `agent` container's exit
/// code and its captured stdout — so `status.exitCode` / `status.output` reflect
/// what actually happened. A pod that has already been GC'd leaves the outcome
/// as-is.
private void enrichFromPod(KubeClient client, string ns, string jobName, ref JobOutcome outcome)
{
	const podName = client.podNameForJob(ns, jobName);
	if (podName.length == 0)
		return;
	const pod = client.podResult(ns, podName);
	outcome.exitCode = pod.exitCode;
	outcome.output = pod.log;
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

private void pruneHistory(KubeClient client, string ns, string stationRef)
{
	Station station;
	try
		station = client.getStation(ns, stationRef);
	catch (NotFound)
		return;

	auto agents = client.listAgents(ns);
	foreach (name; agentsToPrune(agents, station.spec.successfulRunsHistoryLimit,
			station.spec.failedRunsHistoryLimit))
		client.deleteAgent(ns, name);
}

version (unittest)
{
	import fluent.asserts;
	import std.json : JSONValue, parseJSON;
	import agentcore.reconcile : JobState;

	private final class FakeKubeClient : KubeClient
	{
		Station station;
		AgentDefinition definition;
		bool stationMissing;
		JobOutcome outcome;
		Agent[] agents;
		string podNameValue;
		PodResult podResultValue;

		JSONValue[] createdJobs;
		JSONValue[] statusPatches;
		string[] patchedNames;
		string[] deletedAgents;

		override Station getStation(string ns, string name)
		{
			if (stationMissing)
				throw new NotFound("station " ~ name ~ " not found");
			return station;
		}

		override AgentDefinition getAgentDefinition(string ns, string name)
		{
			return definition;
		}

		override void createJob(string ns, JSONValue job)
		{
			createdJobs ~= job;
		}

		override JobOutcome jobOutcome(string ns, string jobName)
		{
			return outcome;
		}

		override void patchAgentStatus(string ns, string name, JSONValue patch)
		{
			patchedNames ~= name;
			statusPatches ~= patch;
		}

		override Agent[] listAgents(string ns)
		{
			return agents;
		}

		override void deleteAgent(string ns, string name)
		{
			deletedAgents ~= name;
		}

		override string podNameForJob(string ns, string jobName)
		{
			return podNameValue;
		}

		override PodResult podResult(string ns, string podName)
		{
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
	client.station.spec.template_ = parseJSON(
		`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
	client.definition.spec.model = "claude-sonnet-4-6";
	client.definition.spec.prompt = "Fix it";

	reconcileAgent(client, "ai-agents", pendingAgent("run-1", "stn"), "img", "2026-06-22T12:00:00Z");

	client.createdJobs.length.should.equal(1);
	client.patchedNames.should.equal(["run-1"]);
	client.statusPatches[0]["status"]["phase"].str.should.equal("Running");
	client.statusPatches[0]["status"]["jobName"].str.should.equal("agent-job-run-1");
	client.statusPatches[0]["status"]["startedAt"].str.should.equal("2026-06-22T12:00:00Z");
}

unittest
{
	// Pending + missing Station -> Failed status, no Job.
	auto client = new FakeKubeClient;
	client.stationMissing = true;

	reconcileAgent(client, "ai-agents", pendingAgent("run-2", "gone"), "img", "2026-06-22T12:00:00Z");

	client.createdJobs.length.should.equal(0);
	client.statusPatches[0]["status"]["phase"].str.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].str.should
		.equal("Station or AgentDefinition not found");
}

unittest
{
	// Pending + Station already at maxConcurrentRuns -> wait: no Job, no patch.
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.maxConcurrentRuns = 1;
	client.station.spec.template_ = parseJSON(`{"spec":{"containers":[{"name":"agent"}]}}`);

	Agent active; // one run already in flight for this Station
	active.metadata.name = "run-active";
	active.spec.stationRef = "stn";
	active.status.phase = Phase.running;
	client.agents = [active];

	reconcileAgent(client, "ai-agents", pendingAgent("run-waiting", "stn"), "img", "now");

	client.createdJobs.length.should.equal(0);
	client.statusPatches.length.should.equal(0);
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
	old.status.phase = Phase.succeeded;
	old.status.completedAt = "2026-06-22T01:00:00Z";
	client.agents = [old];

	Agent agent;
	agent.metadata.name = "run-3";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-3";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z");

	client.statusPatches[0]["status"]["phase"].str.should.equal("Succeeded");
	client.statusPatches[0]["status"]["output"].str.should.equal("the wrapped event log");
	client.statusPatches[0]["status"]["exitCode"].integer.should.equal(0);
	client.deletedAgents.should.equal(["old-success"]);
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

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z");

	client.statusPatches[0]["status"]["phase"].str.should.equal("Failed");
	client.statusPatches[0]["status"]["exitCode"].integer.should.equal(42);
	client.statusPatches[0]["status"]["output"].str.should.equal("boom in the log");
	client.statusPatches[0]["status"]["failureReason"].str.should.equal("BackoffLimitExceeded");
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

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z");

	client.statusPatches.length.should.equal(0);
	client.createdJobs.length.should.equal(0);
}
