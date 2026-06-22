module agentcore.concurrency;

import agentcore.crds.agent : Agent;
import agentcore.types : Phase;

/// Whether a Station has reached its concurrent-run limit. `maxConcurrentRuns` of
/// 0 means unlimited. Counts the Station's Agents currently in `Running`; a
/// `Pending` Agent reconciling against a Station that is at capacity stays pending
/// (the controller retries it on the next reconcile, once a run finishes).
bool stationAtCapacity(const Agent[] agents, string stationRef, int maxConcurrentRuns) @safe
{
	if (maxConcurrentRuns <= 0)
		return false;

	int running;
	foreach (agent; agents)
		if (agent.spec.stationRef == stationRef && agent.status.phase == Phase.running)
			running++;
	return running >= maxConcurrentRuns;
}

version (unittest) import fluent.asserts;

version (unittest) private Agent runFor(string stationRef, Phase phase) @safe
{
	Agent agent;
	agent.spec.stationRef = stationRef;
	agent.status.phase = phase;
	return agent;
}

@safe unittest
{
	auto agents = [
		runFor("stn", Phase.running),
		runFor("stn", Phase.running),
		runFor("stn", Phase.succeeded), // terminal does not count
		runFor("other", Phase.running), // a different Station does not count
		runFor("stn", Phase.pending), // a pending run does not count
	];
	// Two running for "stn": at capacity when the limit is 2, room when it is 3.
	stationAtCapacity(agents, "stn", 2).should.equal(true);
	stationAtCapacity(agents, "stn", 3).should.equal(false);
	// 0 means unlimited.
	stationAtCapacity(agents, "stn", 0).should.equal(false);
}
