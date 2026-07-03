module readiness;

import core.thread : Thread;

/// Readiness the reconcile loops (writers) share with the health server (reader).
/// The controller is ready only when it can reach the API server *and* — while it
/// holds leadership — its poll-driven reconcile sync is not wedged. Gating on the
/// poll loop is deliberate: the poll's full LIST reconciles every Agent, so a
/// healthy poll means reconciliation is happening regardless of the watch's state;
/// a leader whose poll keeps failing is a wedged controller that a rollout must not
/// cut over to. Like `Leadership`, all parties run as cooperative vibe fibers on the
/// one event-loop thread, so the unsynchronized flags are race-free — the accessors
/// bind the owning thread on first touch and assert later access stays on it, so
/// moving a reader/writer onto a worker thread trips loudly in a debug/test build
/// instead of silently becoming a data race.
final class Readiness
{
	private bool apiReachable;
	private bool reconcileHealthy = true; // healthy until a leader's poll proves otherwise
	private Thread owner;

	bool ready() nothrow
	{
		assertOwningThread();
		return apiReachable && reconcileHealthy;
	}

	/// Set by the election tick every replica runs: can this replica reach the API?
	void ready(bool value) nothrow
	{
		assertOwningThread();
		apiReachable = value;
	}

	/// Set by the poll loop: is the leader's reconcile sync healthy? A standby, which
	/// does not reconcile, reports healthy so it is not held out of readiness.
	void reconcileHealth(bool value) nothrow
	{
		assertOwningThread();
		reconcileHealthy = value;
	}

	private void assertOwningThread() nothrow
	{
		auto current = Thread.getThis();
		if (owner is null)
			owner = current;
		else
			assert(owner is current,
				"Readiness accessed off its event-loop thread: the flag is unsynchronized and single-thread-only");
	}
}

version (unittest) import fluent.asserts;

@system unittest
{
	auto readiness = new Readiness();
	// Not ready until the API is reachable, even though reconcile starts healthy.
	readiness.ready.should.equal(false);

	readiness.ready = true;
	readiness.ready.should.equal(true);

	// A wedged leader poll flips reconcile health, dropping readiness even though the
	// API is still reachable.
	readiness.reconcileHealth(false);
	readiness.ready.should.equal(false);

	// Recovery restores readiness.
	readiness.reconcileHealth(true);
	readiness.ready.should.equal(true);
}
