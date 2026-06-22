module agentcore.claude_tool;

import agentcore.agentselect : agentForModel;
import agentcore.initcontext : InitContext;
import agentcore.tool : Tool;

/// Install the Claude CLI via the official installer for every run whose model
/// uses Claude — reusing the same `agentForModel` routing that picks the agent
/// adapter, so "requires Claude" can never drift from "runs ClaudeAgent". The
/// installer self-detects OS/arch/libc and drops `claude` on `~/.local/bin`;
/// `pipefail` plus `curl -f` make a failed download fail the step instead of
/// silently succeeding through the pipe.
final class ClaudeTool : Tool
{
	override string name() const @safe
	{
		return "claude";
	}

	override string[] requires() const @safe
	{
		return ["bash", "curl", "sha256sum"];
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		if (agentForModel(ctx.model).name != "claude")
			return null;
		return [[
			"bash", "-o", "pipefail", "-c",
			"curl -fsSL https://claude.ai/install.sh | bash"
		]];
	}
}

unittest
{
	auto claude = new ClaudeTool;
	assert(claude.name == "claude");
	assert(claude.requires == ["bash", "curl", "sha256sum"]);

	InitContext ctx;

	// Claude models, and the empty/default case, install the CLI
	ctx.model = "claude-sonnet-4-6";
	auto steps = claude.steps(ctx);
	assert(steps.length == 1);
	assert(steps[0][0 .. 4] == ["bash", "-o", "pipefail", "-c"]);
	assert(steps[0][4].canFind("https://claude.ai/install.sh"));

	ctx.model = "";
	assert(claude.steps(ctx).length == 1);

	// Codex / GPT / o-series do not need Claude
	ctx.model = "gpt-5-codex";
	assert(claude.steps(ctx).length == 0);
	ctx.model = "o3-mini";
	assert(claude.steps(ctx).length == 0);
}

version (unittest) import std.algorithm.searching : canFind;
