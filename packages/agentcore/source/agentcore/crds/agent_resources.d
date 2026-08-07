module agentcore.crds.agent_resources;

import agentcore.crds.schema;
import agentcore.crds.env_var : EnvVar;
import agentcore.crds.secret_ref : SecretRef;
import agentcore.crds.mcp_server : McpServer;
import agentcore.crds.repo_ref : RepoRef;

struct AgentResources
{
	@optional EnvVar[] env;
	@optional SecretRef[] secrets;
	@optional @wire("mcp_servers") McpServer[] mcpServers;
	@optional RepoRef[] repos;
	// Names of skills this agent gets. Agent-agnostic: the recipe declares intent
	// ("these skills"); each vendor adapter realizes it. Resolved from the baked
	// image bundle (v1) or the Lore registry (later) and staged into the run's
	// $HOME/.claude/skills by the init — see the SkillsTool.
	@optional string[] skills;
}

@safe unittest
{
	static assert(jsonNameOf!(AgentResources.skills) == "skills");
	static assert(jsonNameOf!(AgentResources.mcpServers) == "mcp_servers");
}
