module agentcore.crds.agent_spec;

import agentcore.crds.schema;
import agentcore.crds.input_file : InputFile;

@Description("One run of a recipe in a Station.")
struct AgentSpec
{
	@optional @Required @Pattern(dns1123Subdomain) @MaxLength(253)
	@Description("The Station to run in (which selects the recipe).")
	string stationRef;

	@optional @Description("External id for correlation.")
	string taskId;

	@optional @Description("GitHub repo in owner/name form.")
	string targetRepo;

	@optional string branch;

	@optional @Description("Per-run values; fill the prompt {placeholder} tokens and pass to the agent.")
	string[string] parameters;

	@optional @Description(
		"Files downloaded into the workspace before the agent starts; only references travel.")
	InputFile[] files;
}
