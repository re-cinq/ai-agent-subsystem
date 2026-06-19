module agentcore.crds.mcp_server;

import agentcore.schema;
import agentcore.crds.enums : McpTransport;

struct McpServer
{
	@Required string name;
	@Required McpTransport transport;
	string command;
	string[] args;
	string url;
	@Json("headers_secret") string headersSecret;
}

@safe unittest
{
	static assert(jsonNameOf!(McpServer.headersSecret) == "headers_secret");
}
