module catalogloop;

import core.time : Duration, MonoTime, seconds;

import vibe.core.core : sleep;
import vibe.core.log : logError, logInfo;

import agentcore.batch.provider : HttpTransport;
import agentcore.models.catalog : ModelCatalogClient, refreshModelCatalog;

import leaderelection : Leadership;
import watchpoll : nowRfc3339;

/// Keep the ModelCatalog current while this replica holds the Lease: refresh it as soon as
/// leadership is won, then every `interval`. A failed refresh is retried on the next tick
/// rather than waiting out the interval.
void runModelCatalogLoop(ModelCatalogClient client, string ns, HttpTransport transport, Duration interval,
	Leadership leadership) nothrow
{
	MonoTime lastRefresh;
	for (;;)
	{
		const now = MonoTime.currTime;
		if (!leadership.isLeader)
			lastRefresh = MonoTime.init;
		else if (catalogRefreshDue(lastRefresh, now, interval))
			try
			{
				refreshModelCatalog(client, ns, transport, nowRfc3339());
				lastRefresh = now;
				logInfo("model catalog refreshed");
			}
			// Throwable, as in the control loop: a vibe-level Error must not end the loop (#88).
			catch (Throwable error)
				logError("model catalog: %s", error.msg);
		try
			sleep(catalogTickSeconds.seconds);
		catch (Exception)
		{
		}
	}
}

/// How often the loop checks leadership and whether a refresh is due.
enum catalogTickSeconds = 30;

/// Whether a refresh is due at `now`: never refreshed this leadership term, or `interval` since the last.
bool catalogRefreshDue(MonoTime lastRefresh, MonoTime now, Duration interval) @safe pure nothrow
{
	return lastRefresh == MonoTime.init || now - lastRefresh >= interval;
}

version (unittest) import fluent.asserts;

unittest // a first refresh is due at once, one 30m ago is not due at a 1h interval, one 1h ago is
{
	const now = MonoTime.currTime;
	[catalogRefreshDue(MonoTime.init, now, 3600.seconds), catalogRefreshDue(now - 1800.seconds, now, 3600.seconds),
		catalogRefreshDue(now - 3600.seconds, now, 3600.seconds)].should.equal([true, false, true]);
}
