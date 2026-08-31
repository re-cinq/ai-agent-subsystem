module agentcore.vendors.gemini.setup;

import agentcore.vendors.base.setup : AgentSetup;

/// Install the Gemini CLI via its official installer. It self-detects OS/arch,
/// downloads the matching release, and drops `gemini` on the path. Guarded by
/// `command -v` so a pre-baked CLI or an init-container retry is a no-op.
final class GeminiSetup : AgentSetup
{
	override string name() const @safe
	{
		return "gemini";
	}

	override string[] requires() const @safe
	{
		return ["bash", "curl"];
	}

	override string[][] installSteps() const @safe
	{
		return [[
			"bash", "-o", "pipefail", "-c",
			"command -v gemini >/dev/null 2>&1 || curl -fsSL https://dl.google.com/gemini/install.sh | bash",
		]];
	}
}

version (unittest) import fluent.asserts;
version (unittest) import std.algorithm.searching : canFind;

@safe unittest
{
	auto gemini = new GeminiSetup;
	gemini.name.should.equal("gemini");
	gemini.requires.should.equal(["bash", "curl"]);

	auto steps = gemini.installSteps;
	steps.length.should.equal(1);
	steps[0][0 .. 4].should.equal(["bash", "-o", "pipefail", "-c"]);
	steps[0][4].canFind("https://dl.google.com/gemini/install.sh").should.equal(true);
	steps[0][4].canFind("command -v gemini").should.equal(true);
}
