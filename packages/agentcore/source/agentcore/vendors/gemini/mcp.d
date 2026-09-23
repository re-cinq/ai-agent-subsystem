module agentcore.vendors.gemini.mcp;

import std.json : JSONOptions, JSONValue;

import agentcore.crds.enums : McpTransport;
import agentcore.crds.mcp_server : McpServer, headerEnvName;

/// The recipe's `mcp_servers` as gemini-cli's `mcpServers` settings object. An
/// Authorization header is a `${NAME}` reference, not the credential: gemini-cli
/// expands `${VAR}` in every settings string when it loads the file, from the pod env
/// where the controller injects the resolved `headers_secret` — the same variable the
/// Claude adapter's `--mcp-config` references, so the token never reaches disk.
string geminiMcpServersJson(in McpServer[] servers) @safe
{
	JSONValue[string] byName;
	foreach (server; servers)
		byName[server.name] = JSONValue(entryOf(server));
	return JSONValue(byName).toString(JSONOptions.doNotEscapeSlashes);
}

private JSONValue[string] entryOf(in McpServer server) @safe
{
	JSONValue[string] entry;
	final switch (server.transport) with (McpTransport)
	{
	case http:
		entry["httpUrl"] = server.url;
		break;
	case sse:
		entry["url"] = server.url;
		break;
	case stdio:
		entry["command"] = server.command;
		if (server.args.length)
			entry["args"] = JSONValue(server.args.dup);
		break;
	}
	if (server.headersSecret.length && server.transport != McpTransport.stdio)
	{
		JSONValue[string] headers;
		headers["Authorization"] = JSONValue("${" ~ headerEnvName(server) ~ "}");
		entry["headers"] = JSONValue(headers);
	}
	return entry;
}

version (unittest)
{
	import fluent.asserts;
	import std.json : parseJSON;
	import agentcore.crds.enums : McpTransport;
}

@safe unittest
{
	// An http server becomes an `httpUrl` entry whose Authorization is a `${NAME}`
	// reference gemini-cli expands from the environment when it loads its settings, so
	// the credential never lands in the file.
	const json = parseJSON(geminiMcpServersJson([
		McpServer("tools", McpTransport.http, "", null, "https://tools-mcp/mcp", "tools-mcp-auth"),
	]));

	json["tools"]["httpUrl"].str.should.equal("https://tools-mcp/mcp");
	json["tools"]["headers"]["Authorization"].str.should.equal("${TOOLS_MCP_AUTH}");
}

unittest
{
	// gemini-cli tells the transports apart by key: `url` is SSE, `command` + `args`
	// is stdio. A server without a headers_secret sends no Authorization header at all,
	// rather than one that expands to an empty string.
	const json = parseJSON(geminiMcpServersJson([
		McpServer("events", McpTransport.sse, "", null, "https://events/sse", ""),
		McpServer("local", McpTransport.stdio, "npx", ["-y", "mcp-local"], "", ""),
	]));

	json["events"].toString.should.equal(`{"url":"https:\/\/events\/sse"}`);
	json["local"]["command"].str.should.equal("npx");
	json["local"]["args"].array.length.should.equal(2);
	("httpUrl" in json["local"].object).should.equal(null);
	("headers" in json["local"].object).should.equal(null);
}
