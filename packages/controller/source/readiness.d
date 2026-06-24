module readiness;

import core.thread : Thread;

/// Readiness flag the reconcile loops (writers) share with the health server
/// (reader): true once the controller has reached the API server, false when it
/// can't. Like `Leadership`, all parties run as cooperative vibe fibers on the one
/// event-loop thread, so the unsynchronized flag is race-free — the accessors bind
/// the owning thread on first touch and assert later access stays on it, so moving a
/// reader/writer onto a worker thread trips loudly in a debug/test build instead of
/// silently becoming a data race.
final class Readiness
{
	private bool flag;
	private Thread owner;

	bool ready() nothrow
	{
		assertOwningThread();
		return flag;
	}

	void ready(bool value) nothrow
	{
		assertOwningThread();
		flag = value;
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
