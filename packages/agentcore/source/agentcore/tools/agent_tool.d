module agentcore.tools.agent_tool;

import agentcore.tools.agentsetup : AgentSetup;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.tool : Tool;

/// Adapts the run's selected `AgentSetup` into the init container's `Tool`
/// pipeline: it installs the one agent CLI the run's model routes to. The setup is
/// chosen upstream (see `agentSetupForModel`), so this tool never inspects the
/// model — it just runs the installer it was handed, on every run.
final class AgentTool : Tool
{
	private AgentSetup setup;

	this(AgentSetup setup) @safe
	{
		this.setup = setup;
	}

	override string name() const @safe
	{
		return setup.name;
	}

	override string[] requires() const @safe
	{
		return setup.requires;
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		return setup.installSteps;
	}
}

version (unittest) import fluent.asserts;
version (unittest) import agentcore.tools.agentsetupselect : agentSetupForModel;

@safe unittest
{
	// A Claude model installs the Claude CLI; a Codex model installs Codex — the
	// same tool, driven by the selected setup. (The old ClaudeTool installed
	// nothing for a Codex run.)
	InitContext ctx;

	ctx.model = "claude-sonnet-4-6";
	auto claude = new AgentTool(agentSetupForModel(ctx.model));
	claude.name.should.equal("claude");
	claude.requires.should.equal(["bash", "curl", "sha256sum"]);
	claude.steps(ctx).length.should.equal(1);

	ctx.model = "gpt-5-codex";
	auto codex = new AgentTool(agentSetupForModel(ctx.model));
	codex.name.should.equal("codex");
	codex.steps(ctx).length.should.equal(1);
}
