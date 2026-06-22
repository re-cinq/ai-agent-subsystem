module watchpoll;

import core.time : seconds;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.json : JSONType, JSONValue, parseJSON;

import vibe.core.core : runTask, sleep;
import vibe.core.log : logError, logInfo;

import agentcore.crds.agent : Agent;
import agentcore.kube.jsonbody : parseAgent;
import agentcore.reconcile.reconcile_driver : reconcileAgent;

import httpkube : HttpKubeClient;

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
/// watch never starves the periodic poll. Both reconnect on error.
void runControlLoop(HttpKubeClient client, string ns, string agentImage) nothrow
{
	runTask(() nothrow { pollLoop(client, ns, agentImage); });
	watchLoop(client, ns, agentImage);
}

private void pollLoop(HttpKubeClient client, string ns, string agentImage) nothrow
{
	for (;;)
	{
		try
		{
			auto agents = client.listAgents(ns);
			logInfo("poll: %s agent(s)", agents.length);
			foreach (agent; agents)
				reconcileOne(client, ns, agent, agentImage);
		}
		catch (Exception error)
			logError("poll: %s", error.msg);

		backoff(15);
	}
}

private void watchLoop(HttpKubeClient client, string ns, string agentImage) nothrow
{
	for (;;)
	{
		try
			client.watchAgents(ns, "0", (string line) {
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
	try
	{
		logInfo("reconcile %s (phase=%s)", agent.metadata.name, cast(string) agent.status.phase);
		reconcileAgent(client, ns, agent, agentImage, nowRfc3339());
	}
	catch (Exception error)
		logError("reconcile %s: %s", agent.metadata.name, error.msg);
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
