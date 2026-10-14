module agentcore.tools.mcp_settings;

import std.json : JSONOptions, JSONType, JSONValue, parseJSON;

/// The settings document `existing` with this run's MCP servers under `key` in place of
/// whatever was there. Every other key survives — a hook bundle's hooks, what the CLI
/// itself persisted — and only `key` is replaced whole, so a server a continued
/// conversation restored from a previous run never outlives the secret that run had.
/// Anything that is not a JSON object, an absent file included, counts as empty.
string mergeMcpSettings(string existing, string key, string serversJson) @safe
{
	JSONValue settings;
	try
		settings = parseJSON(existing);
	catch (Exception)
		settings = parseJSON("{}");
	if (settings.type != JSONType.object)
		settings = parseJSON("{}");
	settings[key] = parseJSON(serversJson);
	return settings.toString(JSONOptions.doNotEscapeSlashes);
}

/// Rewrite the settings file at `path` with `serversJson` merged in under `key`, creating
/// the directory and the file when the run is the first under this $HOME.
void writeMcpSettings(string path, string key, string serversJson) @safe
{
	import std.file : exists, mkdirRecurse, readText, write;
	import std.path : dirName;

	mkdirRecurse(path.dirName);
	const existing = path.exists ? readText(path) : "";
	write(path, mergeMcpSettings(existing, key, serversJson));
}

version (unittest) import fluent.asserts;

unittest
{
	// Merged, not overwritten: a hook bundle's hooks and the CLI's own keys stay, and
	// `mcpServers` is replaced whole, so a server from a previous run is gone.
	const merged = parseJSON(mergeMcpSettings(
		`{"hooks":{"BeforeTool":[]},"mcpServers":{"gone":{"httpUrl":"https://gone/mcp"}}}`, "mcpServers",
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
		parseJSON(mergeMcpSettings(existing, "mcpServers", `{}`)).toString.should.equal(`{"mcpServers":{}}`);
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

	writeMcpSettings(path, "mcpServers", `{"tools":{"httpUrl":"https://tools-mcp/mcp"}}`);
	parseJSON(readText(path))["mcpServers"]["tools"]["httpUrl"].str.should.equal("https://tools-mcp/mcp");

	write(path, `{"theme":"dark","mcpServers":{"tools":{"httpUrl":"https://tools-mcp/mcp"}}}`);
	writeMcpSettings(path, "mcpServers", `{}`);
	const after = parseJSON(readText(path));
	after["theme"].str.should.equal("dark");
	after["mcpServers"].object.length.should.equal(0);
}
