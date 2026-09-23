module agentcore.vendors.gemini.setup;

import agentcore.crds.mcp_server : McpServer;
import agentcore.kube.bundle : geminiMcpSettingsPath, initializerPath;
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
	/// settings. The init re-enters its own binary to merge this run's servers into the
	/// CLI's user settings file (`initializerPath mcp-settings <file> <servers>`): the
	/// system scope v0.11.2 used is refused for a directory uid 1000 owns, and the
	/// slim init image has nothing that can merge JSON in a shell. Emitted for every
	/// Gemini run, servers or none: a continued conversation restores `.gemini` whole,
	/// so an empty `mcpServers` is how a server from a previous run stops being read
	/// with a secret nothing injects any more. The servers ride an argument, never a
	/// script text.
	override string[][] mcpSteps(in McpServer[] servers) const @safe
	{
		return [[initializerPath, "mcp-settings", geminiMcpSettingsPath, geminiMcpServersJson(servers)]];
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
	import std.json : parseJSON;
	import agentcore.crds.enums : McpTransport;

	private const McpServer[] tools = [
		McpServer("tools", McpTransport.http, "", null, "https://tools-mcp/mcp", "tools-mcp-auth"),
	];
}

@safe unittest
{
	// One step that re-enters the init binary against the CLI's user settings file:
	// the one scope gemini-cli loads for a uid-1000 $HOME. The servers ride a
	// positional argument as the `mcpServers` object, the credential as the `${NAME}`
	// reference gemini-cli expands, never a value.
	const steps = (new GeminiSetup).mcpSteps(tools);
	steps.length.should.equal(1);
	steps[0][0 .. 3].should.equal([initializerPath, "mcp-settings", "/agent/.gemini/settings.json"]);
	const servers = parseJSON(steps[0][3]);
	servers["tools"]["httpUrl"].str.should.equal("https://tools-mcp/mcp");
	servers["tools"]["headers"]["Authorization"].str.should.equal("${TOOLS_MCP_AUTH}");
}

@safe unittest
{
	// No servers still writes: an empty object clears what a restored conversation
	// brought back from a run that had some.
	const steps = (new GeminiSetup).mcpSteps([]);
	steps.length.should.equal(1);
	steps[0][3].should.equal("{}");
}
