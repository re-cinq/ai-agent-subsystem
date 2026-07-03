module watchpoll;

import core.time : MonoTime, seconds;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.exception : enforce;
import vibe.data.json : Json, parseJsonString;
import std.random : uniform;

import vibe.core.core : runTask, sleep;
import vibe.core.log : logError, logInfo;

import agentcore.core.types : Phase;
import agentcore.crds.agent : Agent;
import agentcore.kube.jsonbody : parseAgent;
import agentcore.reconcile.reconcile_driver : reconcileAgent, ReconcileEffect;

import cache : AgentCache;
import httpkube : AgentInformerClient, WatchExpired;
import leaderelection : Leadership;
import metrics : recordAgentsByPhase, recordReconcile, recordResync, recordWatchReconnect;
import readiness : Readiness;

/// A decoded line from the Agent watch stream.
struct WatchEvent
{
	string type; /// ADDED, MODIFIED, DELETED, BOOKMARK, ERROR, or "" when unparseable
	Agent agent; /// the parsed object (empty for non-object events)
	string resourceVersion; /// object.metadata.resourceVersion
	int statusCode; /// for ERROR events: the Status object's `code` (e.g. 410 Gone)
	bool parsed; /// whether the object body deserialized cleanly into `agent`
}

/// Decode one `{"type":...,"object":{...}}` watch line. A malformed line yields
/// an empty event (type "") the loop ignores rather than crashing on.
WatchEvent parseWatchLine(string line)
{
	WatchEvent event;
	Json document;
	try
		document = parseJsonString(line);
	catch (Exception)
		return event;

	if (document.type != Json.Type.object)
		return event;

	if (auto type = "type" in document)
		if (type.type == Json.Type.string)
			event.type = type.get!string;

	if (auto object = "object" in document)
	{
		event.resourceVersion = resourceVersionOf(*object);
		event.statusCode = statusCodeOf(*object);
		// A type-mismatched field (e.g. a stored Agent whose status.exitCode is a
		// string) makes fromJson throw. Contain it here — per this function's
		// contract a bad object yields an empty agent, not an exception that
		// escapes into the watch delegate and wedges the loop on a replayed event.
		try
		{
			event.agent = parseAgent(*object);
			event.parsed = true;
		}
		catch (Exception error)
		{
			logError("watch: dropping unparseable object: %s", error.msg);
			event.agent = Agent.init;
		}
		// Keep the name reachable for cache eviction even when the body failed to
		// parse, so a DELETED for a malformed object still evicts.
		if (event.agent.metadata.name.length == 0)
			event.agent.metadata.name = nameOf(*object);
	}

	return event;
}

private string nameOf(Json object)
{
	if (object.type != Json.Type.object)
		return "";
	if (auto meta = "metadata" in object)
		if (meta.type == Json.Type.object)
			if (auto name = "name" in *meta)
				if (name.type == Json.Type.string)
					return name.get!string;
	return "";
}

private string resourceVersionOf(Json object)
{
	if (object.type != Json.Type.object)
		return "";
	if (auto meta = "metadata" in object)
		if (meta.type == Json.Type.object)
			if (auto rv = "resourceVersion" in *meta)
				if (rv.type == Json.Type.string)
					return rv.get!string;
	return "";
}

/// The `code` of an ERROR event's Status object (e.g. 410 when the watch's
/// resourceVersion is too old). 0 for normal events, which carry no `code`.
private int statusCodeOf(Json object)
{
	if (object.type != Json.Type.object)
		return 0;
	if (auto code = "code" in object)
		if (code.type == Json.Type.int_)
			return cast(int) code.get!long;
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
void runControlLoop(AgentInformerClient client, string ns, string agentImage, Leadership leadership,
	Readiness readiness = null) nothrow
{
	auto cache = new AgentCache;
	runTask(() nothrow { pollLoop(client, ns, agentImage, leadership, cache, readiness); });
	informLoop(client, ns, agentImage, leadership, cache);
}

/// The low-latency path: seed the cache + resourceVersion with one LIST, then watch
/// from it, applying each change to the cache and reconciling it. A normal watch
/// close resumes from the last resourceVersion seen (no re-list); a 410 Gone forces
/// a fresh LIST + resync. Losing leadership resets the cursor so a replica that
/// (re)acquires the Lease starts clean. The ~15s poll is the safety net behind this
/// — it, not a timer here, guarantees an event the watch missed is still picked up.
private void informLoop(AgentInformerClient client, string ns, string agentImage, Leadership leadership,
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
				resourceVersion = sync(client, ns, agentImage, cache, leadership);
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
		// Throwable, not Exception: vibe-http raises an AssertError on a response it
		// treats as bodyless, and sync/watch drive that client — the same crash class
		// reconcileOne already contains (#88).
		catch (Throwable error)
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
private string sync(AgentInformerClient client, string ns, string agentImage, AgentCache cache,
	Leadership leadership)
{
	auto page = client.listAllAgents(ns);
	cache.replaceAll(page.items);
	recordResync();
	logInfo("sync: %s agent(s) at resourceVersion %s", page.items.length, page.resourceVersion);
	reconcileAll(client, ns, agentImage, cache, leadership);
	return page.resourceVersion;
}

/// Watch from `resourceVersion`, updating the cache and reconciling each change,
/// returning the last resourceVersion seen so the next watch resumes from it. A
/// 410 ERROR event raises WatchExpired so the caller resyncs.
private string watch(AgentInformerClient client, string ns, string agentImage, Leadership leadership,
	AgentCache cache, string resourceVersion)
{
	string lastVersion = resourceVersion;
	client.watchAgents(ns, resourceVersion, (string line) {
		if (!leadership.isLeader)
			return;
		auto event = parseWatchLine(line);
		enforce(event.type != "ERROR" || event.statusCode != 410,
			new WatchExpired("watch ERROR event: resourceVersion too old (410 Gone)"));
		if (event.resourceVersion.length)
			lastVersion = event.resourceVersion;
		switch (event.type)
		{
		case "ADDED":
		case "MODIFIED":
			// Only act on a cleanly-parsed object: a malformed body must not pollute
			// the cache with a name-only Agent that would then be reconciled. The poll
			// safety net still picks up the real object on its next full LIST.
			if (event.parsed)
			{
				cache.upsert(event.agent);
				reconcileOne(client, ns, event.agent, agentImage, cache.snapshot());
			}
			break;
		case "DELETED":
			if (event.agent.metadata.name.length)
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
private void reconcileAll(AgentInformerClient client, string ns, string agentImage, AgentCache cache,
	Leadership leadership)
{
	auto agents = cache.snapshot();
	recordPhaseGauges(agents);
	// Work on a mutable copy so a run started (or preempted) earlier in THIS pass is
	// reflected in the Station concurrency count the later Agents see. The cache won't
	// carry the new status until the patch round-trips through the informer, so without
	// this a burst of Pending Agents for a capacity-1 Station would all be admitted.
	foreach (ref agent; agents)
	{
		// A leadership loss mid-pass must stop us creating Jobs / issuing deletes from a
		// now-stale cache; the watch path already rechecks this per event.
		if (!leadership.isLeader)
			return;
		const effect = reconcileOne(client, ns, agent, agentImage, agents);
		if (effect.startedRun)
			agent.status.phase = Phase.running;
		if (effect.preemptedAgent.length)
			markTerminal(agents, effect.preemptedAgent);
	}
}

/// Mark the preempted Agent terminal in the pass's working view so it stops counting
/// toward the Station's concurrency limit and is not preempted again this pass.
private void markTerminal(Agent[] agents, string name) nothrow
{
	foreach (ref agent; agents)
		if (agent.metadata.name == name)
		{
			agent.status.phase = Phase.failed;
			return;
		}
}

/// Safety-net poll: every ~15s do a full paginated LIST that refreshes the cache
/// and reconciles every Agent. This is what catches an Agent the watch never
/// delivered — a created/updated Agent whose event was missed or dropped — since
/// the cache-reading reconciles can only act on Agents the cache already holds. The
/// watch is the low-latency path; this is the guarantee.
private void pollLoop(AgentInformerClient client, string ns, string agentImage, Leadership leadership,
	AgentCache cache, Readiness readiness = null) nothrow
{
	int syncFailures = 0;
	for (;;)
	{
		if (!leadership.isLeader)
		{
			// A standby does not reconcile, so it never wedges — don't hold it out
			// of readiness, and clear any streak from a previous leadership term.
			syncFailures = 0;
			markReconcileHealth(readiness, true);
		}
		else
			try
			{
				sync(client, ns, agentImage, cache, leadership);
				syncFailures = 0;
				markReconcileHealth(readiness, true);
			}
			catch (Throwable error) // contain vibe-level Errors too, as reconcileOne does (#88)
			{
				logError("poll: %s", error.msg);
				// A blip is fine; a leader whose poll keeps failing is wedged and must
				// drop out of readiness so a rollout stops cutting over to it.
				if (++syncFailures >= maxConsecutivePollFailures)
					markReconcileHealth(readiness, false);
			}

		backoff(15);
	}
}

/// How many consecutive poll syncs must fail before the leader is considered wedged
/// and drops out of readiness. At the ~15s poll cadence this is ~45s of a dead
/// reconcile before the replica reports not-ready — long enough to ride out a blip.
enum maxConsecutivePollFailures = 3;

private void markReconcileHealth(Readiness readiness, bool healthy) nothrow
{
	if (readiness !is null)
		readiness.reconcileHealth(healthy);
}

private ReconcileEffect reconcileOne(AgentInformerClient client, string ns, Agent agent, string agentImage,
	const Agent[] cached) nothrow
{
	const start = MonoTime.currTime;
	try
	{
		logInfo("reconcile %s (phase=%s)", agent.metadata.name, cast(string) agent.status.phase);
		const effect = reconcileAgent(client, ns, agent, agentImage, nowRfc3339(), cached);
		recordReconcile("success", elapsedSeconds(start));
		return effect;
	}
	// Contain a single Agent's reconcile — including library-level `Error`s, not just
	// `Exception`s — so one bad API interaction can never crash the HA controller. A
	// concrete case: vibe-http's HTTP client asserts (an `AssertError`) when reading
	// the body of a response it treats as bodyless; uncaught, it escaped this nothrow
	// boundary and killed the process. Log, count it, and let the next tick retry
	// (this is what controller-runtime does with a per-reconcile recover()).
	catch (Throwable error)
	{
		recordReconcile("error", elapsedSeconds(start));
		logError("reconcile %s: %s", agent.metadata.name, error.msg);
		return ReconcileEffect.init;
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
	// A type-mismatched field (exitCode is int; here it is a string) makes the typed
	// parse throw. The line must still decode into an event the loop can act on —
	// type, resourceVersion and name intact — rather than throwing into the watch
	// delegate and wedging the loop on a replayed event.
	auto poisoned = parseWatchLine(
		`{"type":"MODIFIED","object":{"metadata":{"name":"run-3","resourceVersion":"99"},` ~
			`"status":{"exitCode":"boom"}}}`);
	poisoned.type.should.equal("MODIFIED");
	poisoned.resourceVersion.should.equal("99");
	poisoned.agent.metadata.name.should.equal("run-3");

	// A DELETED for an otherwise-malformed object still exposes the name to evict.
	auto deletedBad = parseWatchLine(
		`{"type":"DELETED","object":{"metadata":{"name":"run-4"},"status":{"exitCode":"boom"}}}`);
	deletedBad.type.should.equal("DELETED");
	deletedBad.agent.metadata.name.should.equal("run-4");
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

version (unittest)
{
	import agentcore.crds.agent_definition : AgentDefinition;
	import agentcore.crds.station : Station;
	import agentcore.kube.jsonbody : AgentListPage;
	import agentcore.kube.kubeclient : KubeClient, NotFound, PodResult;
	import agentcore.reconcile.reconcile : JobOutcome;

	/// A fake informer that scripts a LIST page and a watch stream, records the reconcile
	/// actions the driver takes, and lets a test drive `sync`/`watch`/`reconcileAll`
	/// without a real API server — the seam the leader election already models.
	private final class FakeInformerClient : AgentInformerClient
	{
		AgentListPage listPage;
		string[] watchLines;
		Station station;
		AgentDefinition definition;
		Leadership flipLeaderOnCreate; /// when set, leadership drops after the first createJob

		Json[] createdJobs;
		string[] patchedNames;
		string[] deletedAgents;

		AgentListPage listAllAgents(string ns)
		{
			return listPage;
		}

		void watchAgents(string ns, string resourceVersion, scope void delegate(string) onLine)
		{
			foreach (line; watchLines)
				onLine(line);
		}

		Station getStation(string ns, string name)
		{
			return station;
		}

		AgentDefinition getAgentDefinition(string ns, string name)
		{
			return definition;
		}

		void createJob(string ns, Json job)
		{
			createdJobs ~= job;
			if (flipLeaderOnCreate !is null)
				flipLeaderOnCreate.isLeader = false;
		}

		JobOutcome jobOutcome(string ns, string jobName)
		{
			return JobOutcome.init;
		}

		void patchAgentStatus(string ns, string name, Json patch)
		{
			patchedNames ~= name;
		}

		void deleteAgent(string ns, string name, string resourceVersion = "")
		{
			deletedAgents ~= name;
		}

		string podNameForJob(string ns, string jobName)
		{
			return "";
		}

		PodResult podResult(string ns, string podName)
		{
			return PodResult.init;
		}
	}

	private Agent pendingRun(string name, string stationRef)
	{
		Agent agent;
		agent.metadata.name = name;
		agent.spec.stationRef = stationRef;
		agent.status.phase = Phase.pending;
		return agent;
	}

	private FakeInformerClient stationClient()
	{
		auto client = new FakeInformerClient;
		client.station.metadata.name = "stn";
		client.station.spec.agentDefRef = "def";
		client.station.spec.template_ = parseJsonString(
			`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
		client.definition.spec.model = "claude-sonnet-4-6";
		client.definition.spec.prompt = "go";
		return client;
	}
}

unittest
{
	// A single poll pass admits only up to the Station's limit even when a burst of
	// Pending Agents all arrive before any status patch round-trips through the cache:
	// the pass counts the runs it starts. Three pending, maxConcurrentRuns 1 -> one Job.
	auto client = stationClient();
	client.station.spec.maxConcurrentRuns = 1;
	client.listPage = AgentListPage(
		[pendingRun("r1", "stn"), pendingRun("r2", "stn"), pendingRun("r3", "stn")], "100", "");

	auto leadership = new Leadership;
	leadership.isLeader = true;
	auto cache = new AgentCache;
	sync(client, "ai-agents", "img", cache, leadership);

	client.createdJobs.length.should.equal(1);
}

unittest
{
	// Losing leadership mid-pass stops the sweep: the first start flips leadership, so
	// the remaining Pending Agents in the same pass are not reconciled.
	auto client = stationClient(); // unlimited concurrency: without the guard all 3 start
	client.listPage = AgentListPage(
		[pendingRun("r1", "stn"), pendingRun("r2", "stn"), pendingRun("r3", "stn")], "100", "");

	auto leadership = new Leadership;
	leadership.isLeader = true;
	client.flipLeaderOnCreate = leadership;
	auto cache = new AgentCache;
	sync(client, "ai-agents", "img", cache, leadership);

	client.createdJobs.length.should.equal(1);
}

unittest
{
	// The watch keeps the cache current: an ADDED upserts, a DELETED evicts, and a
	// poison line (type-mismatched field) is dropped without throwing out of the watch.
	auto client = stationClient();
	client.watchLines = [
		`{"type":"ADDED","object":{"metadata":{"name":"a","resourceVersion":"2"},` ~
			`"spec":{"stationRef":"stn"},"status":{"phase":"Succeeded"}}}`,
		`{"type":"ADDED","object":{"metadata":{"name":"b","resourceVersion":"3"},` ~
			`"spec":{"stationRef":"stn"},"status":{"phase":"Succeeded"}}}`,
		`{"type":"MODIFIED","object":{"metadata":{"name":"c"},"status":{"exitCode":"boom"}}}`,
		`{"type":"DELETED","object":{"metadata":{"name":"a","resourceVersion":"4"}}}`,
	];

	auto leadership = new Leadership;
	leadership.isLeader = true;
	auto cache = new AgentCache;
	const last = watch(client, "ai-agents", "img", leadership, cache, "1");

	cache.length.should.equal(1); // b remains; a added then deleted; c never upserted
	cache.snapshot()[0].metadata.name.should.equal("b");
	last.should.equal("4"); // resumes from the last resourceVersion seen
}

unittest
{
	// A 410 ERROR event raises WatchExpired so the inform loop resyncs from a fresh LIST.
	auto client = stationClient();
	client.watchLines = [`{"type":"ERROR","object":{"kind":"Status","code":410}}`];

	auto leadership = new Leadership;
	leadership.isLeader = true;
	auto cache = new AgentCache;
	watch(client, "ai-agents", "img", leadership, cache, "1").should.throwException!WatchExpired;
}
