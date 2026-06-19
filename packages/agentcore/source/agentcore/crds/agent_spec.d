module agentcore.crds.agent_spec;

import agentcore.schema;

@Description("One run of a recipe in a Station.")
struct AgentSpec
{
	@Required @Description("The Station to run in (which selects the recipe).")
	string stationRef;

	@Description("External id for correlation.")
	string taskId;

	@Description("GitHub repo in owner/name form.")
	string targetRepo;

	string branch;

	@Description("Per-run values; fill the prompt {placeholder} tokens and pass to the agent.")
	string[string] parameters;
}
