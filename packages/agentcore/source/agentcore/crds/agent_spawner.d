module agentcore.crds.agent_spawner;

import agentcore.crds.enums : SpawnerConcurrencyPolicy;
import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.api_group : crApiVersion;
import agentcore.crds.schema;

/// Five whitespace-separated cron fields. Only the shape is checked at admission; the
/// controller parses the values and reports a bad one in its log.
enum cronShape = `^\s*\S+(\s+\S+){4}\s*$`;

/// A repository in `owner/name` form.
enum repositoryShape = `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`;

@Description("Starts a run for each signed GitHub webhook delivery that matches.")
struct GitHubTrigger
{
	@optional @Required @Description("Key in the agent-secrets Secret holding the webhook's HMAC secret.")
	string secretRef;

	@optional @Required @Description(
		"Deliveries that start a run, as <X-GitHub-Event>.<action> (issues.labeled); "
		~ "an event without an action by its name alone.")
	string[] events;

	@optional @Description(
		"Only issues carrying this label start a run; for issues.labeled, only when it is the label just added.")
	string label;

	@optional @Pattern(repositoryShape) @Description("Only deliveries from this owner/name repository start a run.")
	string repository;
}

@Description("Creates an Agent in a Station on a cron schedule, on GitHub webhook deliveries, or both.")
@Validation("has(self.schedule) || has(self.github)", "set schedule, github, or both")
struct AgentSpawnerSpec
{
	@optional @Required @Pattern(dns1123Subdomain) @MaxLength(253)
	@Description("The Station each spawned Agent runs in.")
	string stationRef;

	@optional @Pattern(cronShape)
	@Description("Five-field cron expression (minute hour day-of-month month day-of-week), evaluated in UTC.")
	string schedule;

	@optional @Description("Starts a run for each matching GitHub webhook delivery.")
	GitHubTrigger github;

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

	spawner.spec.should.equal(AgentSpawnerSpec("story-writer", "0 3 * * *", GitHubTrigger.init, ["title": "a"],
		SpawnerConcurrencyPolicy.allow, false));
	spawner.status.lastScheduleTime.should.equal("2026-10-17T03:00:00Z");
}

unittest // a webhook-only spawner parses its github trigger and has no schedule
{
	import vibe.data.json : parseJsonString;
	import agentcore.crds.serialization : fromJson;

	auto spawner = fromJson!AgentSpawner(parseJsonString(`{"spec":{"stationRef":"fixer",
		"github":{"secretRef":"github-webhook","events":["issues.labeled"],"label":"agent","repository":"octo/app"}}}`));

	[spawner.spec.schedule, spawner.spec.github.secretRef, spawner.spec.github.label, spawner.spec.github.repository]
		.should.equal(["", "github-webhook", "agent", "octo/app"]);
	spawner.spec.github.events.should.equal(["issues.labeled"]);
}
