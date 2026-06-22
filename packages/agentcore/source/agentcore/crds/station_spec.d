module agentcore.crds.station_spec;

import std.json : JSONValue;

import agentcore.schema;

@Description("The runtime template that pairs a recipe with a Pod template.")
struct StationSpec
{
	@Required @Description("Name of the AgentDefinition this Station runs.")
	string agentDefRef;

	@Minimum(1) @Description("Wall-clock limit per run; becomes the Job's activeDeadlineSeconds.")
	int deadlineMinutes = 30;

	@Minimum(0) int successfulRunsHistoryLimit = 3;
	@Minimum(0) int failedRunsHistoryLimit = 3;

	@Minimum(0) @Description("Max Agents of this Station running at once; 0 is unlimited. A Pending Agent waits while at the limit.")
	int maxConcurrentRuns = 0;

	@Required @Json("template") @PreserveUnknownFields
	@Description("Standard Kubernetes PodTemplateSpec; the container named \"agent\" is wired with the recipe.")
	JSONValue template_;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	StationSpec s;
	s.deadlineMinutes.should.equal(30);
	s.successfulRunsHistoryLimit.should.equal(3);
	s.maxConcurrentRuns.should.equal(0); // unlimited by default
	static assert(jsonNameOf!(StationSpec.template_) == "template");
	static assert(jsonNameOf!(StationSpec.agentDefRef) == "agentDefRef");
	static assert(isRequired!(StationSpec.agentDefRef));
	static assert(!isRequired!(StationSpec.deadlineMinutes));
}
