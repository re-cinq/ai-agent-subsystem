module agentcore.vendors.opencode.setup;

import agentcore.crds.mcp_server : McpServer;
import agentcore.kube.bundle : initializerPath, opencodeMcpSettingsPath;
import agentcore.vendors.base.setup : AgentSetup, McpSettings;
import agentcore.vendors.opencode.mcp : opencodeMcpJson;

/// Install the OpenCode CLI via its official installer. It self-detects OS/arch,
/// downloads the matching release from GitHub, and drops `opencode` under
/// `~/.opencode/bin`; `pipefail` plus `curl -f` fail the step on a bad download
/// rather than piping an error page into the shell. Guarded by `command -v` so a
/// pre-baked CLI or an init-container retry is a no-op.
final class OpenCodeSetup : AgentSetup, McpSettings
{
	/// OpenCode has no flag for MCP servers; the init merges them into the `mcp` key of
	/// its global config. Emitted with no servers too, so the file never keeps a server
	/// whose secret this run no longer injects.
	override string[][] mcpSteps(in McpServer[] servers) const @safe
	{
		return [[initializerPath, "mcp-settings", opencodeMcpSettingsPath, "mcp", opencodeMcpJson(servers)]];
	}

	override string name() const @safe
	{
		return "opencode";
	}

	override string[] requires() const @safe
	{
		return ["bash", "curl", "tar"];
	}

	override string[][] installSteps() const @safe
	{
		return [[
			"bash", "-o", "pipefail", "-c",
			"command -v opencode >/dev/null 2>&1 || curl -fsSL https://opencode.ai/install | bash",
		]];
	}
}

version (unittest) import fluent.asserts;
version (unittest) import std.algorithm.searching : canFind;

@safe unittest
{
	auto opencode = new OpenCodeSetup;
	opencode.name.should.equal("opencode");
	opencode.requires.should.equal(["bash", "curl", "tar"]);

	auto steps = opencode.installSteps;
	steps.length.should.equal(1);
	steps[0][4].canFind("https://opencode.ai/install").should.equal(true);
	steps[0][4].canFind("command -v opencode").should.equal(true);
}

@safe unittest
{
	(new OpenCodeSetup).mcpSteps(null)
		.should.equal([[initializerPath, "mcp-settings", "/agent/.config/opencode/opencode.json", "mcp", "{}"]]);
}
