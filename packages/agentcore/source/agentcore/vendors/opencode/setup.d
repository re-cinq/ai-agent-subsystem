module agentcore.tools.opencode_setup;

import agentcore.tools.agentsetup : AgentSetup;

/// Install the OpenCode CLI via its official installer. It self-detects OS/arch,
/// downloads the matching release from GitHub, and drops `opencode` under
/// `~/.opencode/bin`; `pipefail` plus `curl -f` fail the step on a bad download
/// rather than piping an error page into the shell. Guarded by `command -v` so a
/// pre-baked CLI or an init-container retry is a no-op.
final class OpenCodeSetup : AgentSetup
{
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
