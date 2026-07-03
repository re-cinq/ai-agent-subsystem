module agentcore.reconcile.prune;

import std.algorithm.sorting : sort;

import agentcore.crds.agent : Agent;
import agentcore.core.types : Phase;

/// Names of the Agents to delete so each terminal phase of one Station keeps
/// only its history limit. Only runs of `stationRef` are considered — one
/// Station's limits must never prune another Station's history (#87). Within a
/// phase the newest runs (by `status.completedAt`, an RFC3339 string that sorts
/// chronologically) are kept; the rest are returned for deletion. Pending and
/// Running Agents are never pruned.
string[] agentsToPrune(const Agent[] agents, string stationRef, int successLimit,
	int failedLimit) @safe
{
	const(Agent)[] stationRuns;
	foreach (agent; agents)
		if (agent.spec.stationRef == stationRef)
			stationRuns ~= agent;
	return overLimit(stationRuns, Phase.succeeded, successLimit)
		~ overLimit(stationRuns, Phase.failed, failedLimit);
}

private string[] overLimit(const Agent[] agents, Phase phase, int limit) @safe
{
	struct Run
	{
		string name;
		string completedAt;
	}

	Run[] runs;
	foreach (agent; agents)
		if (agent.status.phase == phase)
			runs ~= Run(agent.metadata.name, agent.status.completedAt);

	runs.sort!((a, b) => a.completedAt > b.completedAt);

	const size_t keep = limit > 0 ? limit : 0;
	string[] doomed;
	foreach (i, run; runs)
		if (i >= keep)
			doomed ~= run.name;
	return doomed;
}

version (unittest) import fluent.asserts;

version (unittest) private Agent terminalAgent(string name, Phase phase,
	string completedAt, string stationRef = "stn") @safe
{
	Agent agent;
	agent.metadata.name = name;
	agent.spec.stationRef = stationRef;
	agent.status.phase = phase;
	agent.status.completedAt = completedAt;
	return agent;
}

@safe unittest
{
	auto agents = [
		terminalAgent("succ-old", Phase.succeeded, "2026-06-22T10:00:00Z"),
		terminalAgent("succ-new", Phase.succeeded, "2026-06-22T12:00:00Z"),
		terminalAgent("succ-mid", Phase.succeeded, "2026-06-22T11:00:00Z"),
		terminalAgent("still-running", Phase.running, ""),
	];
	// Keep the 2 newest succeeded -> only the oldest is pruned; Running is never pruned.
	agentsToPrune(agents, "stn", 2, 3).should.equal(["succ-old"]);
}

@safe unittest
{
	auto agents = [
		terminalAgent("fail-old", Phase.failed, "2026-06-22T08:00:00Z"),
		terminalAgent("fail-new", Phase.failed, "2026-06-22T09:00:00Z"),
		terminalAgent("succ-a", Phase.succeeded, "2026-06-22T07:00:00Z"),
	];
	// Failed bucket is independent; success limit 0 prunes the whole succeeded bucket.
	agentsToPrune(agents, "stn", 0, 1).should.equal(["succ-a", "fail-old"]);
}

@safe unittest
{
	// Another Station's terminal runs are invisible to this Station's limits:
	// stn pruning with limit 0 keeps other-stn's history intact.
	auto agents = [
		terminalAgent("mine", Phase.succeeded, "2026-06-22T10:00:00Z"),
		terminalAgent("not-mine", Phase.succeeded, "2026-06-22T09:00:00Z", "other-stn"),
		terminalAgent("not-mine-failed", Phase.failed, "2026-06-22T09:00:00Z", "other-stn"),
	];
	agentsToPrune(agents, "stn", 0, 0).should.equal(["mine"]);
}

@safe unittest
{
	// Nothing terminal -> nothing to prune.
	agentsToPrune([terminalAgent("p", Phase.pending, "")], "stn", 3, 3).length.should.equal(0);
}
