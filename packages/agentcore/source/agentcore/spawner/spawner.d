/// AgentSpawner scheduling: when a spawner is due, the Agent it creates, and the status it
/// records. The schedule state lives in the spawner's status, so a controller that restarts
/// or fails over picks up where the last leader stopped.
module agentcore.spawner.spawner;

import std.algorithm.searching : any;
import std.conv : to;
import std.datetime : SysTime, UTC;
import std.typecons : Nullable, nullable;

import vibe.data.json : Json;

import agentcore.core.types : Phase;
import agentcore.crds.agent : Agent;
import agentcore.crds.agent_spawner : AgentSpawner;
import agentcore.crds.api_group : crApiVersion, crGroup;
import agentcore.crds.enums : SpawnerConcurrencyPolicy;
import agentcore.kube.jobs : safeName;
import agentcore.spawner.cron : cronPreviousFire, parseCron;

/// Label on every Agent a spawner creates; its value is the spawner's name.
enum spawnerLabel = crGroup ~ "/spawner";

/// The Kubernetes operations the spawner loop needs.
interface SpawnerClient
{
	/// Every AgentSpawner in the namespace.
	AgentSpawner[] listAgentSpawners(string ns);

	/// The Agents `spawner` created, found by their spawner label.
	Agent[] listSpawnedAgents(string ns, const AgentSpawner spawner);

	/// Create an Agent. One that already exists (HTTP 409) is not an error, so creating
	/// the same schedule slot twice starts one run.
	void createAgent(string ns, Json agent);

	/// Merge-patch the AgentSpawner's `/status` subresource.
	void patchAgentSpawnerStatus(string ns, string name, Json statusPatch);
}

/// What one tick did with a spawner.
enum SpawnOutcome
{
	notDue,
	created,
	skipped, /// due, but Forbid and an earlier run is still going
}

/// The schedule slot to run now: the latest fire time at or before `now`, when it is after
/// the last slot handled (or after the spawner was created, if none was). After an outage
/// that missed several slots this is only the latest one, so the spawner fires once rather
/// than replaying a backlog. Null when suspended or not due; throws on a bad schedule.
Nullable!SysTime spawnDue(const AgentSpawner spawner, SysTime now)
{
	if (spawner.spec.suspend)
		return typeof(return).init;
	auto slot = cronPreviousFire(parseCron(spawner.spec.schedule), now);
	const since = spawner.status.lastScheduleTime.length
		? spawner.status.lastScheduleTime : spawner.metadata.creationTimestamp;
	return slot > SysTime.fromISOExtString(since) ? nullable(slot) : typeof(return).init;
}

/// Whether any of `agents` is still Pending or Running, which makes a Forbid spawner skip its tick.
bool anyUnfinished(Agent[] agents)
{
	return agents.any!(agent => agent.status.phase == Phase.pending || agent.status.phase == Phase.running);
}

/// The Agent `spawner` creates for `slot`. Its name is derived from the slot, so a second
/// create for the same slot (a failover between the create and the status patch) 409s
/// instead of starting a second run. The owner reference garbage-collects it with the spawner.
Json agentFromSpawner(const AgentSpawner spawner, SysTime slot)
{
	Json owner = Json.emptyObject;
	owner["apiVersion"] = crApiVersion;
	owner["kind"] = "AgentSpawner";
	owner["name"] = spawner.metadata.name;
	owner["uid"] = spawner.metadata.uid;
	owner["controller"] = true;
	owner["blockOwnerDeletion"] = true;

	Json labels = Json.emptyObject;
	labels[spawnerLabel] = safeName(spawner.metadata.name);

	Json metadata = Json.emptyObject;
	metadata["name"] = spawnedAgentName(spawner, slot);
	metadata["namespace"] = spawner.metadata.namespace;
	metadata["labels"] = labels;
	metadata["ownerReferences"] = Json([owner]);

	Json parameters = Json.emptyObject;
	foreach (key, value; spawner.spec.parameters)
		parameters[key] = value;

	Json spec = Json.emptyObject;
	spec["stationRef"] = spawner.spec.stationRef;
	spec["parameters"] = parameters;

	Json agent = Json.emptyObject;
	agent["apiVersion"] = crApiVersion;
	agent["kind"] = "Agent";
	agent["metadata"] = metadata;
	agent["spec"] = spec;
	return agent;
}

/// `<spawner>-<slot in minutes since the epoch>`, shortened with a hash past 63 characters.
string spawnedAgentName(const AgentSpawner spawner, SysTime slot)
{
	return safeName(spawner.metadata.name ~ "-" ~ (slot.toUnixTime / 60).to!string);
}

/// The status merge patch recording `slot` as handled and, when one was created, `agentName`.
Json spawnStatusPatch(SysTime slot, string agentName)
{
	Json status = Json.emptyObject;
	status["lastScheduleTime"] = slot.toUTC.toISOExtString;
	if (agentName.length)
		status["lastAgent"] = agentName;
	Json patch = Json.emptyObject;
	patch["status"] = status;
	return patch;
}

/// Run one spawner's tick: create its Agent when due (or skip the slot under Forbid), then
/// record the slot in its status. The Agents it created are listed only when it is due and Forbid.
SpawnOutcome spawnIfDue(SpawnerClient client, string ns, const AgentSpawner spawner, SysTime now)
{
	const slot = spawnDue(spawner, now);
	if (slot.isNull)
		return SpawnOutcome.notDue;

	if (spawner.spec.concurrencyPolicy == SpawnerConcurrencyPolicy.forbid
		&& anyUnfinished(client.listSpawnedAgents(ns, spawner)))
	{
		client.patchAgentSpawnerStatus(ns, spawner.metadata.name, spawnStatusPatch(slot.get, ""));
		return SpawnOutcome.skipped;
	}
	client.createAgent(ns, agentFromSpawner(spawner, slot.get));
	client.patchAgentSpawnerStatus(ns, spawner.metadata.name,
		spawnStatusPatch(slot.get, spawnedAgentName(spawner, slot.get)));
	return SpawnOutcome.created;
}

version (unittest)
{
	import fluent.asserts;
	import vibe.data.json : parseJsonString;

	private SysTime utc(string iso)
	{
		return SysTime.fromISOExtString(iso, UTC());
	}

	private AgentSpawner spawner(string schedule, string lastScheduleTime = "",
		SpawnerConcurrencyPolicy policy = SpawnerConcurrencyPolicy.allow)
	{
		AgentSpawner spawner;
		spawner.metadata.name = "nightly";
		spawner.metadata.namespace = "ai-agents";
		spawner.metadata.uid = "uid-1";
		spawner.metadata.creationTimestamp = "2026-10-17T09:59:30Z";
		spawner.spec.stationRef = "story-writer";
		spawner.spec.schedule = schedule;
		spawner.spec.parameters = ["title": "dragons"];
		spawner.spec.concurrencyPolicy = policy;
		spawner.status.lastScheduleTime = lastScheduleTime;
		return spawner;
	}

	private Agent agentIn(Phase phase)
	{
		Agent agent;
		agent.status.phase = phase;
		return agent;
	}

	private final class FakeSpawnerClient : SpawnerClient
	{
		Agent[] spawned;
		string[] calls;

		AgentSpawner[] listAgentSpawners(string ns)
		{
			return null;
		}

		Agent[] listSpawnedAgents(string ns, const AgentSpawner spawner)
		{
			calls ~= "list " ~ spawner.metadata.name;
			return spawned;
		}

		void createAgent(string ns, Json agent)
		{
			calls ~= "create " ~ agent["metadata"]["name"].get!string;
		}

		void patchAgentSpawnerStatus(string ns, string name, Json statusPatch)
		{
			calls ~= "patch " ~ name ~ " " ~ statusPatch.toString;
		}
	}
}

unittest // a spawner created at 09:59:30 with every-minute schedule is due at 10:00:10 for the 10:00 slot
{
	spawnDue(spawner("* * * * *"), utc("2026-10-17T10:00:10Z")).get.toISOExtString
		.should.equal("2026-10-17T10:00:00Z");
}

unittest // a spawner whose last slot is 10:00 is not due again until 10:05 under */5
{
	const handled = spawner("*/5 * * * *", "2026-10-17T10:00:00Z");
	[spawnDue(handled, utc("2026-10-17T10:04:59Z")).isNull, spawnDue(handled, utc("2026-10-17T10:05:00Z")).isNull]
		.should.equal([true, false]);
}

unittest // after a three-hour outage an hourly spawner fires once, for the latest missed slot
{
	spawnDue(spawner("0 * * * *", "2026-10-17T10:00:00Z"), utc("2026-10-17T13:20:00Z")).get.toISOExtString
		.should.equal("2026-10-17T13:00:00Z");
}

unittest // a suspended spawner is never due
{
	auto suspended = spawner("* * * * *");
	suspended.spec.suspend = true;
	spawnDue(suspended, utc("2026-10-17T12:00:00Z")).isNull.should.equal(true);
}

unittest // a spawner with a bad schedule throws naming the field
{
	spawnDue(spawner("61 * * * *"), utc("2026-10-17T12:00:00Z")).should.throwException!Exception
		.withMessage(`cron minute "61": outside 0-59`);
}

unittest // runs with a Pending or Running Agent are unfinished; Succeeded and Failed ones are not
{
	[anyUnfinished([agentIn(Phase.succeeded), agentIn(Phase.running)]), anyUnfinished([agentIn(Phase.pending)]),
		anyUnfinished([agentIn(Phase.succeeded), agentIn(Phase.failed)])].should.equal([true, true, false]);
}

unittest // the Agent for the 10:00 slot is named by its epoch minute, labelled, owned and carries the parameters
{
	agentFromSpawner(spawner("* * * * *"), utc("2026-10-17T10:00:00Z")).should.equal(parseJsonString(`{
		"apiVersion": "agents.re-cinq.com/v1beta1", "kind": "Agent",
		"metadata": {"name": "nightly-29870520", "namespace": "ai-agents",
			"labels": {"agents.re-cinq.com/spawner": "nightly"},
			"ownerReferences": [{"apiVersion": "agents.re-cinq.com/v1beta1", "kind": "AgentSpawner",
				"name": "nightly", "uid": "uid-1", "controller": true, "blockOwnerDeletion": true}]},
		"spec": {"stationRef": "story-writer", "parameters": {"title": "dragons"}}}`));
}

unittest // a 66-character spawner name gives an Agent name under 64 characters
{
	auto long_ = spawner("* * * * *");
	long_.metadata.name = "spawner-with-a-very-long-name-that-goes-on-and-on-and-on-and-on-xx";
	spawnedAgentName(long_, utc("2026-10-17T10:00:00Z")).length.should.be.lessThan(64);
}

unittest // a due Allow spawner creates the slot's Agent, then records the slot and the Agent without listing runs
{
	auto client = new FakeSpawnerClient;
	spawnIfDue(client, "ai-agents", spawner("* * * * *"), utc("2026-10-17T10:00:10Z")).should.equal(SpawnOutcome.created);
	client.calls.should.equal(["create nightly-29870520",
		`patch nightly {"status":{"lastAgent":"nightly-29870520","lastScheduleTime":"2026-10-17T10:00:00Z"}}`]);
}

unittest // a due Forbid spawner with a Running Agent records the slot as handled and creates nothing
{
	auto client = new FakeSpawnerClient;
	client.spawned = [agentIn(Phase.running)];
	const forbid = spawner("* * * * *", "", SpawnerConcurrencyPolicy.forbid);
	spawnIfDue(client, "ai-agents", forbid, utc("2026-10-17T10:00:10Z")).should.equal(SpawnOutcome.skipped);
	client.calls.should.equal(["list nightly", `patch nightly {"status":{"lastScheduleTime":"2026-10-17T10:00:00Z"}}`]);
}

unittest // a due Forbid spawner whose runs all finished creates the Agent
{
	auto client = new FakeSpawnerClient;
	client.spawned = [agentIn(Phase.succeeded)];
	const forbid = spawner("* * * * *", "", SpawnerConcurrencyPolicy.forbid);
	spawnIfDue(client, "ai-agents", forbid, utc("2026-10-17T10:00:10Z")).should.equal(SpawnOutcome.created);
	client.calls[0 .. 2].should.equal(["list nightly", "create nightly-29870520"]);
}

unittest // a spawner not due makes no API call
{
	auto client = new FakeSpawnerClient;
	spawnIfDue(client, "ai-agents", spawner("* * * * *", "2026-10-17T10:00:00Z"), utc("2026-10-17T10:00:50Z"))
		.should.equal(SpawnOutcome.notDue);
	client.calls.length.should.equal(0);
}
