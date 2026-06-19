module agentcore.crds.agent_resources;

import agentcore.schema;
import agentcore.crds.env_var : EnvVar;
import agentcore.crds.secret_ref : SecretRef;
import agentcore.crds.mcp_server : McpServer;
import agentcore.crds.repo_ref : RepoRef;

struct AgentResources
{
	EnvVar[] env;
	SecretRef[] secrets;
	@Json("mcp_servers") McpServer[] mcpServers;
	RepoRef[] repos;
}
