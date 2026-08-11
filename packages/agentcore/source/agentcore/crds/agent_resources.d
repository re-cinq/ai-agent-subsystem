module agentcore.crds.agent_resources;

import agentcore.crds.schema;
import agentcore.crds.env_var : EnvVar;
import agentcore.crds.secret_ref : SecretRef;
import agentcore.crds.mcp_server : McpServer;
import agentcore.crds.repo_ref : RepoRef;
import agentcore.crds.conversation_ref : ConversationRef;

struct AgentResources
{
	@optional EnvVar[] env;
	@optional SecretRef[] secrets;
	@optional @wire("mcp_servers") McpServer[] mcpServers;
	@optional RepoRef[] repos;
	// Names of skills this agent gets. Agent-agnostic: the recipe declares intent
	// ("these skills"); each vendor adapter realizes it. The init fetches each name
	// from `skillsSource` and stages it (+ the source's settings) into the run's
	// $HOME/.claude — see the SkillsTool. The subsystem knows nothing of the
	// registry beyond the URL the recipe hands it.
	@optional string[] skills;
	// Base URL of the skill/settings registry the recipe's skills come from. The init
	// fetches `<skillsSource>/<name>.tar.gz` per skill and `<skillsSource>/settings.json`.
	// Empty ⇒ no fetch (skills off). Provided by the consumer (e.g. Lore) — kept out of
	// the subsystem so it stays consumer-agnostic.
	@optional @wire("skills_source") string skillsSource;
	// A previous run this one continues (#188 sibling): the init restores the prior
	// state into the vendor's stateDir and the adapter resumes it. Opaque to the
	// subsystem — what the id groups is the consumer's business.
	@optional ConversationRef conversation;
}

@safe unittest
{
	static assert(jsonNameOf!(AgentResources.skills) == "skills");
	static assert(jsonNameOf!(AgentResources.skillsSource) == "skills_source");
	static assert(jsonNameOf!(AgentResources.mcpServers) == "mcp_servers");
}
