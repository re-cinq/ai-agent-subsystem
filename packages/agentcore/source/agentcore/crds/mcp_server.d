module agentcore.crds.mcp_server;

import agentcore.crds.schema;
import agentcore.crds.enums : McpTransport;

struct McpServer
{
	@optional @Required string name;
	@optional @Required McpTransport transport;
	@optional string command;
	@optional string[] args;
	@optional string url;
	@optional @wire("headers_secret") string headersSecret;
}

@safe unittest
{
	static assert(jsonNameOf!(McpServer.headersSecret) == "headers_secret");
}
