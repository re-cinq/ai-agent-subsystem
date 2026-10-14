module agentcore.vendors.opencode.mcp;

import std.json : JSONOptions, JSONValue;

import agentcore.crds.enums : McpTransport;
import agentcore.crds.mcp_server : McpServer, headerCredentials, stdioLaunch;

/// The recipe's `mcp_servers` as OpenCode's `mcp` config object: `local` for stdio
/// (`command` is the whole argv), `remote` for http and sse. A header value is a
/// `{env:NAME}` reference OpenCode expands when it loads the config, from the pod env
/// where the controller injects the resolved `headers_secret`, so the token never
/// reaches disk. A server with a credential also turns OAuth discovery off: the header
/// is its auth, and a headless run has nobody to complete a browser flow.
string opencodeMcpJson(in McpServer[] servers) @safe
{
	JSONValue[string] byName;
	foreach (server; servers)
		byName[server.name] = JSONValue(entryOf(server));
	return JSONValue(byName).toString(JSONOptions.doNotEscapeSlashes);
}

private JSONValue[string] entryOf(in McpServer server) @safe
{
	JSONValue[string] entry;
	entry["enabled"] = true;
	if (server.transport == McpTransport.stdio)
	{
		entry["type"] = "local";
		entry["command"] = JSONValue(stdioLaunch(server));
		return entry;
	}
	entry["type"] = "remote";
	entry["url"] = server.url;
	string[string] headers;
	foreach (header; headerCredentials(server))
		headers[header.name] = "{env:" ~ header.envVar ~ "}";
	if (headers.length)
	{
		entry["headers"] = JSONValue(headers);
		entry["oauth"] = false;
	}
	return entry;
}

version (unittest)
{
	import fluent.asserts;
	import std.json : parseJSON;
}

@safe unittest
{
	const json = parseJSON(opencodeMcpJson([
		McpServer("tools", McpTransport.http, "", null, "https://tools-mcp/mcp", "tools-mcp-auth"),
		McpServer("events", McpTransport.sse, "", null, "https://events/sse", ""),
		McpServer("local", McpTransport.stdio, "npx", ["-y", "mcp-local"], "", ""),
	]));

	json.should.equal(parseJSON(`{
		"tools": {"enabled": true, "type": "remote", "url": "https://tools-mcp/mcp",
			"headers": {"Authorization": "{env:TOOLS_MCP_AUTH}"}, "oauth": false},
		"events": {"enabled": true, "type": "remote", "url": "https://events/sse"},
		"local": {"enabled": true, "type": "local", "command": ["npx", "-y", "mcp-local"]}
	}`));
}

@safe unittest
{
	opencodeMcpJson(null).should.equal("{}");
}

@safe unittest
{
	import agentcore.crds.mcp_server : McpHeader;

	const json = parseJSON(opencodeMcpJson([
		McpServer("tools", McpTransport.http, "", null, "https://t/mcp", "", [McpHeader("X-Api-Key", "k")]),
	]));

	json["tools"]["headers"].should.equal(parseJSON(`{"X-Api-Key": "{env:MCP_TOOLS_X_API_KEY}"}`));
}
