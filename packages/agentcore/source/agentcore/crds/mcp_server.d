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

/// Shell-safe env-var name that carries this server's `headers_secret` value at
/// pod runtime. The controller injects the secret under this name (see
/// `runEnv`) and the Claude adapter references it as `${NAME}` inside the
/// `--mcp-config` JSON, which Claude Code expands from the environment — so both
/// sides MUST derive the name the same way. Uppercased, every non-alphanumeric
/// char folded to `_` (e.g. `lore-mcp-auth` -> `LORE_MCP_AUTH`), because `${}`
/// expansion rejects the hyphens the raw secret key allows. Empty when there is
/// no `headers_secret`.
string headerEnvName(in McpServer server) @safe pure
{
	import std.ascii : isAlphaNum, toUpper;
	import std.array : appender;

	if (!server.headersSecret.length)
		return "";
	auto name = appender!string;
	foreach (char c; server.headersSecret)
		name ~= isAlphaNum(c) ? cast(char) toUpper(c) : '_';
	return name.data;
}

@safe unittest
{
	static assert(jsonNameOf!(McpServer.headersSecret) == "headers_secret");
}

@safe unittest
{
	McpServer server;
	server.headersSecret = "lore-mcp-auth";
	headerEnvName(server).should.equal("LORE_MCP_AUTH");

	McpServer noAuth;
	headerEnvName(noAuth).should.equal("");
}

version (unittest) import fluent.asserts;
