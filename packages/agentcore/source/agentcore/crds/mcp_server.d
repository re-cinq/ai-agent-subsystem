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
/// char folded to `_` (e.g. `tools-mcp-auth` -> `TOOLS_MCP_AUTH`), because `${}`
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

/// Why `servers` cannot be handed to the `vendor` agent CLI, or "" when they can. The
/// exec runner has no CLI to read them and Codex speaks no sse — without this check those
/// servers would be dropped without a word. Each entry needs a unique name that every
/// CLI's config accepts as a key, and the field its transport connects through.
string mcpViolation(in McpServer[] servers, string vendor) @safe pure
{
	import std.algorithm.searching : all, canFind;
	import std.ascii : isAlphaNum;

	if (servers.length && vendor == "exec")
		return "the exec model does not support resources.mcp_servers";
	string[] seen;
	foreach (server; servers)
	{
		if (!server.name.length)
			return "resources.mcp_servers entry has no name";
		if (!server.name.all!(c => c.isAlphaNum || c == '_' || c == '-'))
			return "resources.mcp_servers name \"" ~ server.name ~ "\" may only hold letters, digits, _ and -";
		if (vendor == "codex" && server.transport == McpTransport.sse)
			return "resources.mcp_servers \"" ~ server.name ~ "\": codex does not support sse, use http";
		if (seen.canFind(server.name))
			return "resources.mcp_servers name \"" ~ server.name ~ "\" is not unique";
		seen ~= server.name;
		const needsUrl = server.transport != McpTransport.stdio;
		if (needsUrl && !server.url.length)
			return "resources.mcp_servers \"" ~ server.name ~ "\" needs a url for " ~ server.transport;
		if (!needsUrl && !server.command.length)
			return "resources.mcp_servers \"" ~ server.name ~ "\" needs a command for stdio";
	}
	return "";
}

@safe unittest
{
	static assert(jsonNameOf!(McpServer.headersSecret) == "headers_secret");
}

@safe unittest
{
	const http = McpServer("tools", McpTransport.http, "", null, "https://tools-mcp/mcp", "");
	const stdio = McpServer("local", McpTransport.stdio, "mcp-local", null, "", "");
	const violations = [
		mcpViolation([http, stdio], "codex"),
		mcpViolation(null, "exec"),
		mcpViolation([http], "exec"),
		mcpViolation([McpServer("", McpTransport.http, "", null, "https://x", "")], "claude"),
		mcpViolation([McpServer("my.tools", McpTransport.http, "", null, "https://x", "")], "claude"),
		mcpViolation([McpServer("events", McpTransport.sse, "", null, "https://x", "")], "codex"),
		mcpViolation([http, http], "claude"),
		mcpViolation([McpServer("sse", McpTransport.sse, "", null, "", "")], "claude"),
		mcpViolation([McpServer("local", McpTransport.stdio, "", null, "", "")], "claude"),
	];
	violations.should.equal([
		"",
		"",
		"the exec model does not support resources.mcp_servers",
		"resources.mcp_servers entry has no name",
		`resources.mcp_servers name "my.tools" may only hold letters, digits, _ and -`,
		`resources.mcp_servers "events": codex does not support sse, use http`,
		`resources.mcp_servers name "tools" is not unique`,
		`resources.mcp_servers "sse" needs a url for sse`,
		`resources.mcp_servers "local" needs a command for stdio`,
	]);
}

@safe unittest
{
	McpServer server;
	server.headersSecret = "tools-mcp-auth";
	headerEnvName(server).should.equal("TOOLS_MCP_AUTH");

	McpServer noAuth;
	headerEnvName(noAuth).should.equal("");
}

version (unittest) import fluent.asserts;
