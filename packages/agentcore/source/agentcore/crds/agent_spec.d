module agentcore.crds.agent_spec;

import agentcore.crds.schema;

@Description("One run of a recipe in a Station.")
struct AgentSpec
{
	@optional @Required @Description("The Station to run in (which selects the recipe).")
	string stationRef;

	@optional @Description("External id for correlation.")
	string taskId;

	@optional @Description("GitHub repo in owner/name form.")
	string targetRepo;

	@optional string branch;

	@optional @Description("Per-run values; fill the prompt {placeholder} tokens and pass to the agent.")
	string[string] parameters;
}
