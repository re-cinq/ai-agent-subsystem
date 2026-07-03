module agentcore.vendors.codex.setup;

import agentcore.vendors.base.setup : AgentSetup;

/// Install the OpenAI Codex CLI via its official standalone installer — the same
/// self-detecting `install.sh` the Codex docs ship, not the npm path, so no Node
/// runtime has to be provisioned first. It self-detects OS/arch and drops `codex`
/// under the user's local bin. Guarded by `command -v` so a pre-baked CLI (the
/// integration-test mock) or an init-container retry is a no-op.
final class CodexSetup : AgentSetup
{
	override string name() const @safe
	{
		return "codex";
	}

	override string[] requires() const @safe
	{
		return ["bash", "curl", "tar"];
	}

	override string[][] installSteps() const @safe
	{
		return [[
			"bash", "-o", "pipefail", "-c",
			"command -v codex >/dev/null 2>&1 || curl -fsSL https://chatgpt.com/codex/install.sh | sh",
		]];
	}
}

version (unittest) import fluent.asserts;
version (unittest) import std.algorithm.searching : canFind;

@safe unittest
{
	auto codex = new CodexSetup;
	codex.name.should.equal("codex");
	codex.requires.should.equal(["bash", "curl", "tar"]);

	auto steps = codex.installSteps;
	steps.length.should.equal(1);
	steps[0][4].canFind("https://chatgpt.com/codex/install.sh").should.equal(true);
	steps[0][4].canFind("command -v codex").should.equal(true);
}
