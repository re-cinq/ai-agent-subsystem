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
}
