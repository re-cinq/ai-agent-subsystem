module agentcore.vendors.gemini.mcp;

import std.json : JSONOptions, JSONType, JSONValue, parseJSON;

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

/// The user settings document with this run's `mcpServers` in place of whatever was
/// there. gemini-cli reads the user file (`$HOME/.gemini/settings.json`) without the
/// root-ownership check it applies to its system scope, so this is the one scope a
/// uid-1000 pod can hand servers to. Every other key survives — a hook bundle's hooks,
/// what the CLI itself persisted — and only `mcpServers` is replaced whole, so a
/// server a continued conversation restored from a previous run never outlives the
/// secret that run had. Anything that is not a JSON object, an absent file included,
/// counts as empty.
string mergeMcpSettings(string existing, string mcpServersJson) @safe
{
	JSONValue settings;
	try
		settings = parseJSON(existing);
	catch (Exception)
		settings = JSONValue.emptyObject;
	if (settings.type != JSONType.object)
		settings = JSONValue.emptyObject;
	settings["mcpServers"] = parseJSON(mcpServersJson);
	return settings.toString(JSONOptions.doNotEscapeSlashes);
}

/// Rewrite the settings file at `path` with `mcpServersJson` merged in, creating the
/// directory and the file when the run is the first under this $HOME.
void writeMcpSettings(string path, string mcpServersJson) @safe
{
	import std.file : exists, mkdirRecurse, readText, write;
	import std.path : dirName;

	mkdirRecurse(path.dirName);
	const existing = path.exists ? readText(path) : "";
	write(path, mergeMcpSettings(existing, mcpServersJson));
}

version (unittest)
{
	import fluent.asserts;
	import agentcore.crds.enums : McpTransport;
}

unittest
{
	// Merged, not overwritten: a hook bundle's hooks and the CLI's own keys stay, and
	// `mcpServers` is replaced whole, so a server from a previous run is gone.
	const merged = parseJSON(mergeMcpSettings(
		`{"hooks":{"BeforeTool":[]},"mcpServers":{"gone":{"httpUrl":"https://gone/mcp"}}}`,
		`{"tools":{"httpUrl":"https://tools-mcp/mcp"}}`));

	merged["hooks"]["BeforeTool"].array.length.should.equal(0);
	merged["mcpServers"]["tools"]["httpUrl"].str.should.equal("https://tools-mcp/mcp");
	("gone" in merged["mcpServers"].object).should.equal(null);
}

@safe unittest
{
	// No file, an empty file, a file that is not JSON, or JSON that is not an object:
	// each is an empty document to merge into, never a failed init.
	foreach (existing; ["", "not json", "[1,2]", `"str"`])
		parseJSON(mergeMcpSettings(existing, `{}`)).toString.should.equal(`{"mcpServers":{}}`);
}

unittest
{
	import std.file : exists, readText, rmdirRecurse, tempDir, write;
	import std.path : buildPath;

	// A fresh $HOME has neither `.gemini` nor the file: both are created. A second
	// write under the same $HOME merges into what is there.
	const dir = buildPath(tempDir, "ai-agent-gemini-user-settings");
	scope (exit) if (dir.exists) rmdirRecurse(dir);
	const path = buildPath(dir, ".gemini", "settings.json");

	writeMcpSettings(path, `{"tools":{"httpUrl":"https://tools-mcp/mcp"}}`);
	parseJSON(readText(path))["mcpServers"]["tools"]["httpUrl"].str.should.equal("https://tools-mcp/mcp");

	write(path, `{"theme":"dark","mcpServers":{"tools":{"httpUrl":"https://tools-mcp/mcp"}}}`);
	writeMcpSettings(path, `{}`);
	const after = parseJSON(readText(path));
	after["theme"].str.should.equal("dark");
	after["mcpServers"].object.length.should.equal(0);
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
