module agentcore.vendors.gemini.setup;

import agentcore.crds.mcp_server : McpServer;
import agentcore.kube.bundle : geminiBypassPolicyPath, geminiExperimentsPath, geminiMcpSettingsPath,
	initializerPath;
import agentcore.vendors.base.setup : AgentSetup, McpSettings;
import agentcore.vendors.gemini.experiments : geminiExperimentsJson;
import agentcore.vendors.gemini.mcp : geminiMcpServersJson;
import agentcore.vendors.gemini.policy : geminiBypassPolicyToml;

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
	///
	/// The second step writes the experiments file `GEMINI_EXP` names (see
	/// `GeminiAgent.env`). It rides this tool because it must land last, after a
	/// restored conversation: the restore extracts a previous run's `.gemini` over
	/// the directory, and a stale file from it would otherwise win. Path and JSON
	/// are positional arguments, never script text.
	///
	/// The third writes the bypass policy the same way and for the same reason. It is
	/// inert unless a bypass run's command names it with `--policy` (`GeminiAgent`).
	override string[][] mcpSteps(in McpServer[] servers) const @safe
	{
If `gemini-cli` crashes when a `--policy` directory does not exist and no hook bundle provided one, you may want to ensure it exists before the CLI starts by adding `mkdir -p /agent/.gemini/policies` to the init steps.

		return [
			[initializerPath, "mcp-settings", geminiMcpSettingsPath, geminiMcpServersJson(servers)],
			["bash", "-c", write, "write-experiments", geminiExperimentsPath, geminiExperimentsJson],
			["bash", "-c", write, "write-policy", geminiBypassPolicyPath, geminiBypassPolicyToml],
		];
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
	steps.length.should.equal(3);
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
	steps.length.should.equal(3);
	steps[0][3].should.equal("{}");
}

@safe unittest
{
	// The experiments file is written on every run, servers or none, with exactly the
	// document gemini-cli reads through `GEMINI_EXP`: a 600 s request timeout.
	const steps = (new GeminiSetup).mcpSteps([]);
	steps[1][0 .. 2].should.equal(["bash", "-c"]);
	steps[1][$ - 2 .. $].should.equal([
		"/agent/.gemini/experiments.json",
		`{"flags":[{"flagId":45773134,"intValue":"600"}]}`,
	]);
}

@safe unittest
{
	// The bypass policy is written on every run, after a restored conversation, so a
	// stale copy never wins; only a bypass run's command names it (`GeminiAgent`).
	const steps = (new GeminiSetup).mcpSteps([]);
	steps[2][0 .. 2].should.equal(["bash", "-c"]);
	steps[2][$ - 2 .. $].should.equal([
		"/agent/.gemini/bypass-policy.toml",
		"[[rule]]\ntoolName = \"*\"\ndecision = \"allow\"\npriority = 100\nallowRedirection = true\n\n"
			~ "[[rule]]\ntoolName = \"ask_user\"\ndecision = \"deny\"\npriority = 200",
	]);
}
