module agentcore.vendors.gemini.setup;

import agentcore.crds.mcp_server : McpServer;
import agentcore.kube.bundle : geminiSettingsPath;
import agentcore.vendors.base.setup : AgentSetup, McpSettings;
import agentcore.vendors.gemini.mcp : geminiMcpServersJson;

/// Install the Gemini CLI from its npm tarball, without npm. Gemini ships no
/// curl installer — the URL v0.10.8 used (dl.google.com/gemini/install.sh)
/// does not exist and 404s every gemini run at init — and the init container
/// is debian-slim with no node, so `npm install -g` cannot run where install
/// steps run. What slim DOES have is curl and tar, and the @google/gemini-cli
/// package is a dependency-free self-contained bundle (`bin` -> bundle/
/// gemini.js, zero deps), so the tarball itself is the whole install: fetch,
/// extract into the shared HOME, and drop a `node` wrapper on the path. The
/// wrapper resolves $HOME at run time, in the main container, which is also
/// the container that actually has node — gemini-cli needs node >= 20 there
/// regardless of how it is installed. Guarded by `command -v` so a pre-baked
/// CLI or an init-container retry is a no-op.
final class GeminiSetup : AgentSetup, McpSettings
{
	/// gemini-cli has no flag for MCP servers; it reads them from `mcpServers` in its
	/// settings. A registry hook bundle may already have written that file, so the
	/// servers are merged in with jq rather than written over it. `$1` is the rendered
	/// servers and `$2` the file: nothing from the recipe enters the script text.
	override string[][] mcpSteps(in McpServer[] servers) const @safe
	{
		if (!servers.length)
			return [];
		return [[
			"sh", "-c",
			`mkdir -p "$(dirname "$2")" && { [ -s "$2" ] || printf '{}' > "$2"; }`
				~ ` && jq --argjson servers "$1" '.mcpServers = ((.mcpServers // {}) + $servers)'`
				~ ` "$2" > "$2.tmp" && mv "$2.tmp" "$2"`,
			"sh", geminiMcpServersJson(servers), geminiSettingsPath,
		]];
	}

	override string name() const @safe
	{
		return "gemini";
	}

	override string[] requires() const @safe
	{
		return ["bash", "curl", "tar"];
	}

	override string[][] installSteps() const @safe
	{
		return [[
			"bash", "-o", "pipefail", "-c",
			`command -v gemini >/dev/null 2>&1 || {
  ver=$(curl -fsSL https://registry.npmjs.org/@google/gemini-cli/latest | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  test -n "$ver"
  mkdir -p "$HOME/.local/share/gemini-cli" "$HOME/.local/bin"
  curl -fsSL "https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-$ver.tgz" | tar -xz -C "$HOME/.local/share/gemini-cli"
  printf '#!/usr/bin/env bash\nexec node "$HOME/.local/share/gemini-cli/package/bundle/gemini.js" "$@"\n' > "$HOME/.local/bin/gemini"
  chmod +x "$HOME/.local/bin/gemini"
}`,
		]];
	}
}

version (unittest) import fluent.asserts;
version (unittest) import std.algorithm.searching : canFind;

@safe unittest
{
	auto gemini = new GeminiSetup;
	gemini.name.should.equal("gemini");
	gemini.requires.should.equal(["bash", "curl", "tar"]);

	auto steps = gemini.installSteps;
	steps.length.should.equal(1);
	steps[0][0 .. 4].should.equal(["bash", "-o", "pipefail", "-c"]);
	// The npm registry tarball, not an installer script: no gemini curl
	// installer exists (v0.10.8's URL 404ed every run), and the package is a
	// dependency-free bundle, so the tarball IS the install.
	steps[0][4].canFind("registry.npmjs.org/@google/gemini-cli").should.equal(true);
	steps[0][4].canFind("tar -xz").should.equal(true);
	steps[0][4].canFind("bundle/gemini.js").should.equal(true);
	steps[0][4].canFind("command -v gemini").should.equal(true);
}

version (unittest)
{
	import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
	import std.json : parseJSON;
	import std.path : buildPath;
	import std.process : execute;
	import agentcore.crds.enums : McpTransport;

	private const McpServer[] tools = [
		McpServer("tools", McpTransport.http, "", null, "https://tools-mcp/mcp", "tools-mcp-auth"),
	];

	/// Run `step` as the init would, but against `path` instead of the bundle's file.
	private void runAgainst(const string[] step, string path)
	{
		const ran = execute(step[0 .. $ - 1] ~ path);
		ran.status.should.equal(0);
	}
}

@safe unittest
{
	// One step, the servers riding a positional argument and never the script text, so
	// nothing from the recipe is spliced into shell. No servers, no step.
	const steps = (new GeminiSetup).mcpSteps(tools);
	steps.length.should.equal(1);
	steps[0][0 .. 2].should.equal(["sh", "-c"]);
	steps[0][2].canFind("tools-mcp").should.equal(false);
	steps[0][$ - 2].canFind("https://tools-mcp/mcp").should.equal(true);
	steps[0][$ - 1].should.equal(geminiSettingsPath);
	(new GeminiSetup).mcpSteps([]).length.should.equal(0);
}

unittest
{
	// The step merges into whatever the registry's hook bundle already put in the file:
	// its hooks and its own MCP servers survive, the recipe's servers are added, and
	// the credential is the `${NAME}` reference gemini-cli expands, never a value.
	const dir = buildPath(tempDir, "ai-agent-gemini-mcp-merge");
	scope (exit) if (dir.exists) rmdirRecurse(dir);
	mkdirRecurse(dir);
	const path = buildPath(dir, "settings.json");
	write(path, `{"hooks":{"BeforeTool":[]},"mcpServers":{"org":{"url":"https://org/sse"}}}`);

	runAgainst((new GeminiSetup).mcpSteps(tools)[0], path);

	auto settings = parseJSON(readText(path));
	settings["hooks"].toString.should.equal(`{"BeforeTool":[]}`);
	settings["mcpServers"]["org"]["url"].str.should.equal("https://org/sse");
	settings["mcpServers"]["tools"]["headers"]["Authorization"].str.should.equal("${TOOLS_MCP_AUTH}");
}

unittest
{
	// A run with no hook bundle has neither the directory nor the file yet.
	const dir = buildPath(tempDir, "ai-agent-gemini-mcp-fresh");
	scope (exit) if (dir.exists) rmdirRecurse(dir);
	const path = buildPath(dir, ".gemini", "settings.json");

	runAgainst((new GeminiSetup).mcpSteps(tools)[0], path);

	parseJSON(readText(path))["mcpServers"]["tools"]["httpUrl"].str.should.equal("https://tools-mcp/mcp");
}
