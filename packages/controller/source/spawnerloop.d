module spawnerloop;

import core.time : seconds;
import std.datetime : Clock, SysTime, UTC;

import vibe.core.core : sleep;
import vibe.core.log : logError, logInfo;

import agentcore.spawner.spawner : SpawnOutcome, SpawnerClient, spawnIfDue;

import leaderelection : Leadership;

/// Start the runs of every due AgentSpawner while this replica holds the Lease. The slots
/// handled are kept in each spawner's status, so a new leader neither repeats nor drops one.
void runSpawnerLoop(SpawnerClient client, string ns, Leadership leadership) nothrow
{
	for (;;)
	{
		if (leadership.isLeader)
			try
				spawnTick(client, ns, Clock.currTime(UTC()));
			// Throwable, as in the control loop: a vibe-level Error must not end the loop (#88).
			catch (Throwable error)
				logError("agent spawners: %s", error.msg);
		try
			sleep(spawnerTickSeconds.seconds);
		catch (Exception)
		{
		}
	}
}

/// How often the loop looks for due spawners, and so the most a run starts after its slot.
enum spawnerTickSeconds = 15;

/// One pass over the namespace's spawners. A spawner that fails (a bad schedule, a rejected
/// create) is logged and the rest still run.
void spawnTick(SpawnerClient client, string ns, SysTime now)
{
	foreach (spawner; client.listAgentSpawners(ns))
		try
			logOutcome(spawner.metadata.name, spawnIfDue(client, ns, spawner, now));
		catch (Exception error)
			logError("agent spawner %s: %s", spawner.metadata.name, error.msg);
}

private void logOutcome(string name, SpawnOutcome outcome)
{
	if (outcome == SpawnOutcome.created)
		logInfo("agent spawner %s: created a run", name);
	if (outcome == SpawnOutcome.skipped)
		logInfo("agent spawner %s: skipped a tick, its previous run is still going (Forbid)", name);
}

version (unittest)
{
	import fluent.asserts;
	import vibe.data.json : Json;

	import agentcore.crds.agent : Agent;
	import agentcore.crds.agent_spawner : AgentSpawner;

	private final class FakeSpawnerClient : SpawnerClient
	{
		AgentSpawner[] spawners;
		string[] created;

		AgentSpawner[] listAgentSpawners(string ns)
		{
			return spawners;
		}

		Agent[] listSpawnedAgents(string ns, const AgentSpawner spawner)
		{
			return null;
		}

		void createAgent(string ns, Json agent)
		{
			created ~= agent["metadata"]["name"].get!string;
		}

		void patchAgentSpawnerStatus(string ns, string name, Json statusPatch)
		{
		}
	}

	private AgentSpawner spawner(string name, string schedule)
	{
		AgentSpawner spawner;
		spawner.metadata.name = name;
		spawner.metadata.creationTimestamp = "2026-10-17T09:00:00Z";
		spawner.spec.stationRef = "story-writer";
		spawner.spec.schedule = schedule;
		return spawner;
	}
}

unittest // a spawner with a bad schedule does not stop the next one from creating its run
{
	auto client = new FakeSpawnerClient;
	client.spawners = [spawner("broken", "99 * * * *"), spawner("hourly", "0 * * * *")];
	spawnTick(client, "ai-agents", SysTime.fromISOExtString("2026-10-17T10:00:05Z", UTC()));
	client.created.should.equal(["hourly-29870520"]);
}
