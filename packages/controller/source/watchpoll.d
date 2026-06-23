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

import httpkube : HttpKubeClient;
import leaderelection : Leadership;
import metrics : recordAgentsByPhase, recordReconcile, recordWatchReconnect;

/// A decoded line from the Agent watch stream.
struct WatchEvent
{
	string type; /// ADDED, MODIFIED, DELETED, BOOKMARK, ERROR, or "" when unparseable
	Agent agent; /// the parsed object (empty for non-object events)
	string resourceVersion; /// object.metadata.resourceVersion
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

/// The controller's reconcile engine: a low-latency watch and an independent
/// ~15s safety-net poll, running as two concurrent vibe tasks so a long-lived
/// watch never starves the periodic poll. Both reconnect on error and only
/// reconcile while this replica holds leadership, so standbys stay idle.
void runControlLoop(HttpKubeClient client, string ns, string agentImage, Leadership leadership) nothrow
{
	runTask(() nothrow { pollLoop(client, ns, agentImage, leadership); });
	watchLoop(client, ns, agentImage, leadership);
}

private void pollLoop(HttpKubeClient client, string ns, string agentImage, Leadership leadership) nothrow
{
	for (;;)
	{
		if (leadership.isLeader)
			try
			{
				auto agents = client.listAgents(ns);
				logInfo("poll: %s agent(s)", agents.length);
					recordPhaseGauges(agents);
				foreach (agent; agents)
					reconcileOne(client, ns, agent, agentImage);
			}
			catch (Exception error)
				logError("poll: %s", error.msg);

		backoff(15);
	}
}

private void watchLoop(HttpKubeClient client, string ns, string agentImage, Leadership leadership) nothrow
{
	bool firstConnect = true;
	for (;;)
	{
		if (!firstConnect)
			recordWatchReconnect();
		firstConnect = false;
		try
			client.watchAgents(ns, "0", (string line) {
				if (!leadership.isLeader)
					return;
				auto event = parseWatchLine(line);
				if (event.type == "ADDED" || event.type == "MODIFIED")
					reconcileOne(client, ns, event.agent, agentImage);
			});
		catch (Exception error)
			logError("watch: %s", error.msg);

		backoff(2);
	}
}

private void reconcileOne(HttpKubeClient client, string ns, Agent agent, string agentImage) nothrow
{
	const start = MonoTime.currTime;
	try
	{
		logInfo("reconcile %s (phase=%s)", agent.metadata.name, cast(string) agent.status.phase);
		reconcileAgent(client, ns, agent, agentImage, nowRfc3339());
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
