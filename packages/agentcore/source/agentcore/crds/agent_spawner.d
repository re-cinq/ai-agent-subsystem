module agentcore.crds.agent_spawner;

import agentcore.crds.enums : SpawnerConcurrencyPolicy;
import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.api_group : crApiVersion;
import agentcore.crds.schema;

/// Five whitespace-separated cron fields. Only the shape is checked at admission; the
/// controller parses the values and reports a bad one in its log.
enum cronShape = `^\s*\S+(\s+\S+){4}\s*$`;

@Description("Creates an Agent in a Station on a cron schedule.")
struct AgentSpawnerSpec
{
	@optional @Required @Pattern(dns1123Subdomain) @MaxLength(253)
	@Description("The Station each spawned Agent runs in.")
	string stationRef;

	@optional @Required @Pattern(cronShape)
	@Description("Five-field cron expression (minute hour day-of-month month day-of-week), evaluated in UTC.")
	string schedule;

	@optional @Description("Copied verbatim into every spawned Agent's spec.parameters.")
	string[string] parameters;

	@optional @Description(
		"Allow starts a run on every tick; Forbid skips a tick while an Agent this spawner created is not finished.")
	SpawnerConcurrencyPolicy concurrencyPolicy = SpawnerConcurrencyPolicy.allow;

	@optional @Description("True stops new runs; runs already started are left alone.")
	bool suspend;
}

struct AgentSpawnerStatus
{
	@optional @Description("RFC3339 schedule time of the last tick handled, whether it created an Agent or was skipped.")
	@Format("date-time") string lastScheduleTime;

	@optional @Description("Name of the last Agent this spawner created.")
	string lastAgent;
}

@CurrentVersionOnly
@Plural("agentspawners")
@ShortNames(["asp"])
@PrinterColumn("Schedule", "string", ".spec.schedule")
@PrinterColumn("Station", "string", ".spec.stationRef")
@PrinterColumn("Suspend", "boolean", ".spec.suspend")
@PrinterColumn("Last Schedule", "date", ".status.lastScheduleTime")
@PrinterColumn("Age", "date", ".metadata.creationTimestamp")
struct AgentSpawner
{
	@optional string apiVersion = crApiVersion;
	@optional string kind = "AgentSpawner";
	@optional ObjectMeta metadata;
	@optional AgentSpawnerSpec spec;
	@optional AgentSpawnerStatus status;
}

version (unittest) import fluent.asserts;

unittest // a spawner parsed from a manifest with an unknown concurrencyPolicy falls back to Allow
{
	import vibe.data.json : parseJsonString;
	import agentcore.crds.serialization : fromJson;

	auto spawner = fromJson!AgentSpawner(parseJsonString(`{"metadata":{"name":"nightly"},
		"spec":{"stationRef":"story-writer","schedule":"0 3 * * *","concurrencyPolicy":"Replace",
		"parameters":{"title":"a"}},"status":{"lastScheduleTime":"2026-10-17T03:00:00Z"}}`));

	spawner.spec.should.equal(AgentSpawnerSpec("story-writer", "0 3 * * *", ["title": "a"],
		SpawnerConcurrencyPolicy.allow, false));
	spawner.status.lastScheduleTime.should.equal("2026-10-17T03:00:00Z");
	static assert(isRequired!(AgentSpawnerSpec.schedule));
}
