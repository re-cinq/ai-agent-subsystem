module watchpoll;

import core.time : MonoTime, seconds;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.json : JSONType, JSONValue, parseJSON;

import vibe.core.core : runTask, sleep;
import vibe.core.log : logError, logInfo;

import agentcore.core.types : Phase;
import agentcore.crds.agent : Agent;
import agentcore.kube.jsonbody : parseAgent;
import agentcore.reconcile.reconcile_driver : reconcileAgent;

import cache : AgentCache;
import httpkube : HttpKubeClient, WatchExpired;
import leaderelection : Leadership;
import metrics : recordAgentsByPhase, recordReconcile, recordResync, recordWatchReconnect;

/// How often the informer re-LISTs the namespace even while the watch is healthy:
/// drift insurance against any missed event, well above the per-change watch path.
enum resyncIntervalSeconds = 300;

/// A decoded line from the Agent watch stream.
struct WatchEvent
{
	string type; /// ADDED, MODIFIED, DELETED, BOOKMARK, ERROR, or "" when unparseable
	Agent agent; /// the parsed object (empty for non-object events)
	string resourceVersion; /// object.metadata.resourceVersion
	int statusCode; /// for ERROR events: the Status object's `code` (e.g. 410 Gone)
}

/// Decode one `{"type":...,"object":{...}}` watch line. A malformed line yields
/// an empty event (type "") the loop ignores rather than crashing on.
WatchEvent parseWatchLine(string line)
{
	WatchEvent event;
	JSONValue document;
	try
		document = parseJSON(line);
	catch (Exception)
		return event;

	if (document.type != JSONType.object)
		return event;
	if (auto type = "type" in document.object)
		if (type.type == JSONType.string)
			event.type = type.str;
	if (auto object = "object" in document.object)
	{
		event.agent = parseAgent(*object);
		event.resourceVersion = resourceVersionOf(*object);
		event.statusCode = statusCodeOf(*object);
	}
	return event;
}

private string resourceVersionOf(JSONValue object)
{
	if (object.type != JSONType.object)
		return "";
	if (auto meta = "metadata" in object.object)
		if (meta.type == JSONType.object)
			if (auto rv = "resourceVersion" in meta.object)
				if (rv.type == JSONType.string)
					return rv.str;
	return "";
}

/// The `code` of an ERROR event's Status object (e.g. 410 when the watch's
/// resourceVersion is too old). 0 for normal events, which carry no `code`.
private int statusCodeOf(JSONValue object)
{
	if (object.type != JSONType.object)
		return 0;
	if (auto code = "code" in object.object)
		if (code.type == JSONType.integer)
			return cast(int) code.integer;
	return 0;
}

/// The controller's reconcile engine, an informer: a full paginated LIST seeds an
/// in-memory cache and the watch's starting resourceVersion, then a long-lived
/// watch keeps the cache current and reconciles each change. Concurrency counts and
/// history pruning read the cache instead of re-listing, so steady-state cost is
/// O(changed). A second task sweeps the cache on a ~15s safety net. Only the Lease
/// holder reconciles, so standbys stay idle.
void runControlLoop(HttpKubeClient client, string ns, string agentImage, Leadership leadership) nothrow
{
	auto cache = new AgentCache;
	runTask(() nothrow { sweepLoop(client, ns, agentImage, leadership, cache); });
	informLoop(client, ns, agentImage, leadership, cache);
}

/// List-then-watch with resourceVersion resume: a normal watch close resumes from
/// the last resourceVersion (no re-list); a 410 Gone forces a resync; a slow
/// periodic resync re-lists anyway as drift insurance. Losing leadership resets the
/// cursor so a replica that (re)acquires the Lease starts from a clean sync.
private void informLoop(HttpKubeClient client, string ns, string agentImage, Leadership leadership,
	AgentCache cache) nothrow
{
	string resourceVersion;
	long lastSyncUnix;
	bool firstWatch = true;
	for (;;)
	{
		if (!leadership.isLeader)
		{
			resourceVersion = "";
			firstWatch = true;
			backoff(2);
			continue;
		}
		try
		{
			if (resourceVersion.length == 0 || nowUnix() - lastSyncUnix >= resyncIntervalSeconds)
			{
				resourceVersion = sync(client, ns, agentImage, cache);
				lastSyncUnix = nowUnix();
			}
			if (!firstWatch)
				recordWatchReconnect();
			firstWatch = false;
			resourceVersion = watch(client, ns, agentImage, leadership, cache, resourceVersion);
		}
		catch (WatchExpired expired)
		{
			logInfo("watch expired, resyncing: %s", expired.msg);
			resourceVersion = "";
		}
		catch (Exception error)
			logError("inform: %s", error.msg);

		backoff(2);
	}
}

/// Full paginated LIST: replace the cache, reconcile every cached Agent once, and
/// return the list's resourceVersion for the watch to resume from.
private string sync(HttpKubeClient client, string ns, string agentImage, AgentCache cache)
{
	auto page = client.listAllAgents(ns);
	cache.replaceAll(page.items);
	recordResync();
	logInfo("sync: %s agent(s) at resourceVersion %s", page.items.length, page.resourceVersion);
	reconcileAll(client, ns, agentImage, cache);
	return page.resourceVersion;
}

/// Watch from `resourceVersion`, updating the cache and reconciling each change,
/// returning the last resourceVersion seen so the next watch resumes from it. A
/// 410 ERROR event raises WatchExpired so the caller resyncs.
private string watch(HttpKubeClient client, string ns, string agentImage, Leadership leadership,
	AgentCache cache, string resourceVersion)
{
	string lastVersion = resourceVersion;
	client.watchAgents(ns, resourceVersion, (string line) {
		if (!leadership.isLeader)
			return;
		auto event = parseWatchLine(line);
		if (event.type == "ERROR" && event.statusCode == 410)
			throw new WatchExpired("watch ERROR event: resourceVersion too old (410 Gone)");
		if (event.resourceVersion.length)
			lastVersion = event.resourceVersion;
		switch (event.type)
		{
		case "ADDED":
		case "MODIFIED":
			cache.upsert(event.agent);
			reconcileOne(client, ns, event.agent, agentImage, cache.snapshot());
			break;
		case "DELETED":
			cache.remove(event.agent.metadata.name);
			break;
		default:
			break; // BOOKMARK only advanced lastVersion; unparseable lines are ignored
		}
	});
	return lastVersion;
}

/// Reconcile every cached Agent against the current snapshot — the post-sync pass
/// and the periodic safety net. Terminal Agents short-circuit with no I/O, so this
/// is O(actionable) API calls, not O(all).
private void reconcileAll(HttpKubeClient client, string ns, string agentImage, AgentCache cache)
{
	auto agents = cache.snapshot();
	recordPhaseGauges(agents);
	foreach (agent; agents)
		reconcileOne(client, ns, agent, agentImage, agents);
}

/// Safety net: every ~15s re-reconcile the cached Agents (no LIST) so a Pending
/// Agent that was at capacity, or anything a missed event left stale, gets another
/// chance. Reads the same cache the informer fills.
private void sweepLoop(HttpKubeClient client, string ns, string agentImage, Leadership leadership,
	AgentCache cache) nothrow
{
	for (;;)
	{
		if (leadership.isLeader)
			try
				reconcileAll(client, ns, agentImage, cache);
			catch (Exception error)
				logError("sweep: %s", error.msg);

		backoff(15);
	}
}

private void reconcileOne(HttpKubeClient client, string ns, Agent agent, string agentImage,
	const Agent[] cached) nothrow
{
	const start = MonoTime.currTime;
	try
	{
		logInfo("reconcile %s (phase=%s)", agent.metadata.name, cast(string) agent.status.phase);
		reconcileAgent(client, ns, agent, agentImage, nowRfc3339(), cached);
		recordReconcile("success", elapsedSeconds(start));
	}
	catch (Exception error)
	{
		recordReconcile("error", elapsedSeconds(start));
		logError("reconcile %s: %s", agent.metadata.name, error.msg);
	}
}

/// Tally how many Agents sit in each phase right now, for the agents-by-phase
/// gauge. Every phase is set each poll (including 0) so a drained phase decays
/// instead of holding its last non-zero reading.
private void recordPhaseGauges(Agent[] agents) nothrow
{
	static immutable Phase[] phases = [Phase.pending, Phase.running, Phase.succeeded, Phase.failed];
	foreach (phase; phases)
		recordAgentsByPhase(cast(string) phase, countInPhase(agents, phase));
}

/// Count how many of `agents` sit in `phase`. Pure so the tally is unit-testable
/// apart from the metrics side effect `recordPhaseGauges` wraps around it.
size_t countInPhase(const Agent[] agents, Phase phase) @safe pure nothrow
{
	size_t count;
	foreach (ref agent; agents)
		if (agent.status.phase == phase)
			count++;
	return count;
}

private double elapsedSeconds(MonoTime start) nothrow
{
	return (MonoTime.currTime - start).total!"nsecs" / 1e9;
}

private void backoff(int secs) nothrow
{
	try
		sleep(secs.seconds);
	catch (Exception)
	{
	}
}

private string nowRfc3339()
{
	return Clock.currTime(UTC()).toISOExtString();
}

private long nowUnix()
{
	return Clock.currTime(UTC()).toUnixTime();
}

version (unittest) import fluent.asserts;

unittest
{
	auto event = parseWatchLine(
		`{"type":"ADDED","object":{"metadata":{"name":"run-1","resourceVersion":"42"},` ~
			`"spec":{"stationRef":"s"},"status":{"phase":"Pending"}}}`);
	event.type.should.equal("ADDED");
	event.agent.metadata.name.should.equal("run-1");
	event.resourceVersion.should.equal("42");

	parseWatchLine("not json").type.should.equal("");
}

unittest
{
	// A 410 ERROR event exposes the Status code so the loop resyncs.
	auto expired = parseWatchLine(`{"type":"ERROR","object":{"kind":"Status","code":410}}`);
	expired.type.should.equal("ERROR");
	expired.statusCode.should.equal(410);

	// A DELETED event still carries the object name for cache eviction.
	auto deleted = parseWatchLine(
		`{"type":"DELETED","object":{"metadata":{"name":"run-9","resourceVersion":"77"}}}`);
	deleted.type.should.equal("DELETED");
	deleted.agent.metadata.name.should.equal("run-9");
	deleted.resourceVersion.should.equal("77");
}

unittest
{
	Agent pending, runningOne, runningTwo, succeeded;
	pending.status.phase = Phase.pending;
	runningOne.status.phase = Phase.running;
	runningTwo.status.phase = Phase.running;
	succeeded.status.phase = Phase.succeeded;
	const agents = [pending, runningOne, runningTwo, succeeded];

	countInPhase(agents, Phase.running).should.equal(2);
	countInPhase(agents, Phase.pending).should.equal(1);
	countInPhase(agents, Phase.succeeded).should.equal(1);
	countInPhase(agents, Phase.failed).should.equal(0);
}
