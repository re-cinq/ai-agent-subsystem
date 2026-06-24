module watchpoll;

import core.time : MonoTime, seconds;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.json : JSONType, JSONValue, parseJSON;
import std.random : uniform;

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

/// The controller's reconcile engine: a low-latency informer watch plus an
/// independent ~15s safety-net poll, sharing one in-memory cache and running as two
/// vibe tasks. The watch resumes from the last resourceVersion (no full replay) and
/// applies each change to the cache; the poll does a full paginated LIST that
/// refreshes the cache and reconciles every Agent, catching anything the watch
/// never delivered. Concurrency counts and history pruning read the cache rather
/// than re-listing per reconcile, so reconcile work is O(changed). Only the Lease
/// holder reconciles, so standbys stay idle.
void runControlLoop(HttpKubeClient client, string ns, string agentImage, Leadership leadership) nothrow
{
	auto cache = new AgentCache;
	runTask(() nothrow { pollLoop(client, ns, agentImage, leadership, cache); });
	informLoop(client, ns, agentImage, leadership, cache);
}

/// The low-latency path: seed the cache + resourceVersion with one LIST, then watch
/// from it, applying each change to the cache and reconciling it. A normal watch
/// close resumes from the last resourceVersion seen (no re-list); a 410 Gone forces
/// a fresh LIST + resync. Losing leadership resets the cursor so a replica that
/// (re)acquires the Lease starts clean. The ~15s poll is the safety net behind this
/// — it, not a timer here, guarantees an event the watch missed is still picked up.
private void informLoop(HttpKubeClient client, string ns, string agentImage, Leadership leadership,
	AgentCache cache) nothrow
{
	string resourceVersion;
	bool firstWatch = true;
	int errorAttempt = 0;
	for (;;)
	{
		if (!leadership.isLeader)
		{
			resourceVersion = "";
			firstWatch = true;
			errorAttempt = 0;
			backoff(watchBackoffBaseSeconds);
			continue;
		}
		try
		{
			if (resourceVersion.length == 0)
				resourceVersion = sync(client, ns, agentImage, cache);
			if (!firstWatch)
				recordWatchReconnect();
			firstWatch = false;
			resourceVersion = watch(client, ns, agentImage, leadership, cache, resourceVersion);
			errorAttempt = 0;
			backoff(watchBackoffBaseSeconds);
		}
		catch (WatchExpired expired)
		{
			logInfo("watch expired, resyncing: %s", expired.msg);
			resourceVersion = "";
			errorAttempt = 0;
			backoff(watchBackoffBaseSeconds);
		}
		catch (Exception error)
		{
			// A real failure (API blip, TLS, 5xx): back off exponentially with jitter
			// instead of hammering a degraded API server every 2s.
			logError("inform: %s", error.msg);
			errorBackoff(++errorAttempt);
		}
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

/// Reconcile every cached Agent against the current snapshot — the pass `sync`
/// runs after refreshing the cache. Terminal Agents short-circuit with no I/O, so
/// this is O(actionable) API calls, not O(all).
private void reconcileAll(HttpKubeClient client, string ns, string agentImage, AgentCache cache)
{
	auto agents = cache.snapshot();
	recordPhaseGauges(agents);
	foreach (agent; agents)
		reconcileOne(client, ns, agent, agentImage, agents);
}

/// Safety-net poll: every ~15s do a full paginated LIST that refreshes the cache
/// and reconciles every Agent. This is what catches an Agent the watch never
/// delivered — a created/updated Agent whose event was missed or dropped — since
/// the cache-reading reconciles can only act on Agents the cache already holds. The
/// watch is the low-latency path; this is the guarantee.
private void pollLoop(HttpKubeClient client, string ns, string agentImage, Leadership leadership,
	AgentCache cache) nothrow
{
	for (;;)
	{
		if (leadership.isLeader)
			try
				sync(client, ns, agentImage, cache);
			catch (Exception error)
				logError("poll: %s", error.msg);

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

/// Base and cap (seconds) for the inform loop's error backoff.
enum watchBackoffBaseSeconds = 2;
enum watchBackoffCapSeconds = 60;

/// Exponential backoff ceiling for the Nth consecutive error: base * 2^attempt,
/// capped at `cap`. Pure so the schedule is testable; the loop layers jitter on top
/// (a random delay up to the ceiling) so replicas don't retry in lockstep.
int backoffCeiling(int attempt, int base, int cap) @safe pure nothrow
{
	long delay = base;
	foreach (_; 0 .. attempt)
	{
		delay *= 2;
		if (delay >= cap)
			return cap;
	}
	return cast(int) delay;
}

/// Sleep before retrying after `attempt` consecutive errors: at least the base
/// delay, plus jitter up to the exponential ceiling, so a persistent failure backs
/// off instead of hot-looping and N replicas don't synchronize their retries.
private void errorBackoff(int attempt) nothrow
{
	const ceiling = backoffCeiling(attempt, watchBackoffBaseSeconds, watchBackoffCapSeconds);
	int secs = ceiling;
	try
		secs = watchBackoffBaseSeconds + uniform(0, ceiling - watchBackoffBaseSeconds + 1);
	catch (Exception)
	{
	}
	backoff(secs);
}

private string nowRfc3339()
{
	return Clock.currTime(UTC()).toISOExtString();
}

version (unittest) import fluent.asserts;

@safe unittest
{
	// Exponential growth from the base, doubling each attempt, capped.
	backoffCeiling(0, 2, 60).should.equal(2);
	backoffCeiling(1, 2, 60).should.equal(4);
	backoffCeiling(2, 2, 60).should.equal(8);
	backoffCeiling(3, 2, 60).should.equal(16);
	// Past the cap it stays at the cap, never unbounded.
	backoffCeiling(10, 2, 60).should.equal(60);
	backoffCeiling(100, 2, 60).should.equal(60);
}

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
