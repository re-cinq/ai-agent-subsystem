module cache;

import agentcore.crds.agent : Agent;

/// The controller's informer-style view of the namespace's Agents, keyed by name.
/// Seeded by a full (paginated) LIST on each (re)sync and kept current by watch
/// events. Concurrency counts, history pruning and the safety-net sweep all read
/// from here instead of re-listing the API server every reconcile, which is what
/// keeps reconcile cost O(changed) rather than O(all).
///
/// Plain thread-local state, no locking: the watch, sweep and election run as vibe
/// tasks on the one event-loop thread (the same race-free assumption
/// leaderelection.d documents), so the cache is only ever touched from that thread.
final class AgentCache
{
	private Agent[string] byName;

	/// Replace the whole cache with a fresh LIST result (initial sync, or resync
	/// after a 410). Drops any Agents that disappeared while we were not watching.
	void replaceAll(Agent[] agents)
	{
		byName = null;
		foreach (agent; agents)
			byName[agent.metadata.name] = agent;
	}

	/// Insert or replace an Agent from an ADDED/MODIFIED watch event.
	void upsert(Agent agent)
	{
		byName[agent.metadata.name] = agent;
	}

	/// Evict an Agent from a DELETED watch event.
	void remove(string name)
	{
		byName.remove(name);
	}

	/// The current set of cached Agents — the input for concurrency counts, history
	/// pruning and the periodic sweep.
	Agent[] snapshot()
	{
		return byName.values;
	}

	/// Number of Agents currently cached.
	size_t length() const
	{
		return byName.length;
	}
}

version (unittest)
{
	import fluent.asserts;
	import agentcore.core.types : Phase;
}

unittest
{
	auto cache = new AgentCache;

	Agent a, b;
	a.metadata.name = "a";
	a.status.phase = Phase.running;
	b.metadata.name = "b";
	b.status.phase = Phase.pending;
	cache.replaceAll([a, b]);
	cache.length.should.equal(2);

	// upsert replaces the entry with the same name rather than adding a duplicate.
	Agent a2;
	a2.metadata.name = "a";
	a2.status.phase = Phase.succeeded;
	cache.upsert(a2);
	cache.length.should.equal(2);

	// remove evicts by name, leaving only the upserted "a" whose phase changed.
	cache.remove("b");
	cache.length.should.equal(1);
	cache.snapshot()[0].metadata.name.should.equal("a");
	cache.snapshot()[0].status.phase.should.equal(Phase.succeeded);

	// replaceAll drops everything the previous sync held.
	cache.replaceAll([b]);
	cache.length.should.equal(1);
	cache.snapshot()[0].metadata.name.should.equal("b");
}
