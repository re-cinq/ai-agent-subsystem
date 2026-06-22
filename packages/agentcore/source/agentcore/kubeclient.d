module agentcore.kubeclient;

import std.json : JSONValue;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.station : Station;
import agentcore.reconcile : JobOutcome;

/// Thrown by `getStation` / `getAgentDefinition` when the referenced resource is
/// absent. The driver maps it to a missing-ref reconcile decision rather than
/// letting it abort the loop.
class NotFound : Exception
{
	this(string message) @safe pure nothrow
	{
		super(message);
	}
}

/// The terminal result of a run pod: the agent container's real exit code and the
/// stdout it captured (the wrapped event stream the supervisor echoed). Used to
/// enrich an Agent's `status.exitCode` / `status.output` beyond what the Job's
/// conditions alone carry.
struct PodResult
{
	int exitCode;
	string log;
}

/// The Kubernetes operations the reconcile driver needs, behind an interface so
/// the driver, Job builder, and pruning stay pure and fake-testable — the same
/// posture as `decide()`. The data crossing the seam is the existing CRD model
/// plus `reconcile.JobOutcome`; no HTTP type leaks to the driver. The real
/// vibe-d implementation is the transport slice; this is all the driver sees.
interface KubeClient
{
	/// Resolve a Station by name; throws `NotFound` when it does not exist.
	Station getStation(string ns, string name);

	/// Resolve an AgentDefinition by name; throws `NotFound` when it does not exist.
	AgentDefinition getAgentDefinition(string ns, string name);

	/// Create the run Job. An already-existing Job (HTTP 409) is not an error —
	/// creation is idempotent so a re-reconcile is safe.
	void createJob(string ns, JSONValue job);

	/// The terminal/running outcome of a previously created Job.
	JobOutcome jobOutcome(string ns, string jobName);

	/// Merge-patch the Agent's `/status` subresource.
	void patchAgentStatus(string ns, string name, JSONValue statusPatch);

	/// Every Agent in the namespace — the source list for history pruning.
	Agent[] listAgents(string ns);

	/// Delete a pruned Agent by name.
	void deleteAgent(string ns, string name);

	/// Name of the pod backing a Job (label `job-name=<jobName>`), or "" if none
	/// has been scheduled yet.
	string podNameForJob(string ns, string jobName);

	/// The run pod's terminal result — the `agent` container's exit code and its
	/// captured stdout — used to enrich the Agent status on a terminal transition.
	PodResult podResult(string ns, string podName);
}
