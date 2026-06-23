module agentcore.reconcile.concurrency;

import agentcore.crds.agent : Agent;
import agentcore.crds.enums : ConcurrencyPolicy;
import agentcore.core.types : Phase;

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

/// The concurrent-run cap implied by the policy: Allow honours `maxConcurrentRuns`
/// (0 = unlimited); Forbid and Replace cap at a single run.
int effectiveMaxRuns(ConcurrencyPolicy policy, int maxConcurrentRuns) @safe pure nothrow
{
	final switch (policy)
	{
	case ConcurrencyPolicy.allow:
		return maxConcurrentRuns;
	case ConcurrencyPolicy.forbid:
	case ConcurrencyPolicy.replace:
		return 1;
	}
}

/// The oldest Running run for a Station, by `status.startedAt` (RFC3339, so a
/// lexical compare is chronological) — the run the Replace policy preempts to make
/// room. "" when none of the Station's Agents is Running.
string oldestRunningRun(const Agent[] agents, string stationRef) @safe
{
	string oldest;
	string oldestStarted;
	foreach (agent; agents)
	{
		if (agent.spec.stationRef != stationRef || agent.status.phase != Phase.running)
			continue;
		if (oldest.length == 0 || agent.status.startedAt < oldestStarted)
		{
			oldest = agent.metadata.name;
			oldestStarted = agent.status.startedAt;
		}
	}
	return oldest;
}

version (unittest) import fluent.asserts;

version (unittest) private Agent runFor(string stationRef, Phase phase) @safe
{
	Agent agent;
	agent.spec.stationRef = stationRef;
	agent.status.phase = phase;
	return agent;
}

version (unittest) private Agent startedRun(string stationRef, string name, string startedAt) @safe
{
	Agent agent;
	agent.metadata.name = name;
	agent.spec.stationRef = stationRef;
	agent.status.phase = Phase.running;
	agent.status.startedAt = startedAt;
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

@safe unittest
{
	// Allow honours the configured cap; Forbid and Replace force a single run.
	effectiveMaxRuns(ConcurrencyPolicy.allow, 3).should.equal(3);
	effectiveMaxRuns(ConcurrencyPolicy.allow, 0).should.equal(0); // unlimited
	effectiveMaxRuns(ConcurrencyPolicy.forbid, 5).should.equal(1);
	effectiveMaxRuns(ConcurrencyPolicy.replace, 5).should.equal(1);
}

@safe unittest
{
	auto agents = [
		startedRun("stn", "run-new", "2026-06-22T11:00:00Z"),
		startedRun("stn", "run-old", "2026-06-22T10:00:00Z"), // earliest startedAt
		runFor("other", Phase.running), // a different Station does not count
		runFor("stn", Phase.pending), // a pending run is not Running
	];
	// The earliest-started Running run for the Station is the one Replace preempts.
	oldestRunningRun(agents, "stn").should.equal("run-old");
	// None Running -> "".
	oldestRunningRun([runFor("stn", Phase.pending)], "stn").should.equal("");
}
