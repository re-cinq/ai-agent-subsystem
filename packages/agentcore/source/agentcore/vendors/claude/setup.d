module agentcore.tools.claude_setup;

import agentcore.tools.agentsetup : AgentSetup;

/// Install the Claude Code CLI via the official installer. It self-detects
/// OS/arch/libc, verifies a SHA256 checksum from the release manifest, and drops
/// `claude` on `~/.local/bin`; `pipefail` plus `curl -f` make a failed download
/// fail the step instead of succeeding silently through the pipe. Guarded by
/// `command -v` so a pre-baked CLI or an init-container retry is a no-op.
final class ClaudeSetup : AgentSetup
{
	override string name() const @safe
	{
		return "claude";
	}

	override string[] requires() const @safe
	{
		return ["bash", "curl", "sha256sum"];
	}

	override string[][] installSteps() const @safe
	{
		return [[
			"bash", "-o", "pipefail", "-c",
			"command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash",
		]];
	}
}

version (unittest) import fluent.asserts;
version (unittest) import std.algorithm.searching : canFind;

@safe unittest
{
	auto claude = new ClaudeSetup;
	claude.name.should.equal("claude");
	claude.requires.should.equal(["bash", "curl", "sha256sum"]);

	auto steps = claude.installSteps;
	steps.length.should.equal(1);
	steps[0][0 .. 4].should.equal(["bash", "-o", "pipefail", "-c"]);
	steps[0][4].canFind("https://claude.ai/install.sh").should.equal(true);
	steps[0][4].canFind("command -v claude").should.equal(true);
}
