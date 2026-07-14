module agentcore.crds.station_spec;

import vibe.data.json : Json;

import agentcore.crds.enums : ConcurrencyPolicy;
import agentcore.crds.schema;

@Description("The runtime template that pairs a recipe with a Pod template.")
struct StationSpec
{
	@optional @Required @Pattern(dns1123Subdomain) @MaxLength(253)
	@Description("Name of the AgentDefinition this Station runs.")
	string agentDefRef;

	@optional @Minimum(1) @Description("Wall-clock limit per run; becomes the Job's activeDeadlineSeconds.")
	int deadlineMinutes = 30;

	@optional @Minimum(0) int successfulRunsHistoryLimit = 3;
	@optional @Minimum(0) int failedRunsHistoryLimit = 3;

	@optional @Minimum(0) @Description("Max Agents of this Station running at once; 0 is unlimited. A Pending Agent waits while at the limit.")
	int maxConcurrentRuns = 0;

	@optional @Description("At the limit: Allow queues (default), Forbid caps at one, Replace cancels the oldest run for the new one.")
	ConcurrencyPolicy concurrencyPolicy = ConcurrencyPolicy.allow;

	@optional @Required @wire("template") @PreserveUnknownFields
	@Description("Standard Kubernetes PodTemplateSpec; the container named \"agent\" is wired with the recipe.")
	Json template_;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	StationSpec s;
	s.deadlineMinutes.should.equal(30);
	s.successfulRunsHistoryLimit.should.equal(3);
	s.maxConcurrentRuns.should.equal(0); // unlimited by default
	s.concurrencyPolicy.should.equal(ConcurrencyPolicy.allow); // queue by default
	static assert(jsonNameOf!(StationSpec.template_) == "template");
	static assert(jsonNameOf!(StationSpec.agentDefRef) == "agentDefRef");
	static assert(isRequired!(StationSpec.agentDefRef));
	static assert(!isRequired!(StationSpec.deadlineMinutes));
}
