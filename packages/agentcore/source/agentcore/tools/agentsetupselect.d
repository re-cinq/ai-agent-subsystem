module agentcore.tools.agentsetupselect;

import agentcore.agents.agentselect : agentForModel;
import agentcore.tools.agentsetup : AgentSetup;
import agentcore.tools.claude_setup : ClaudeSetup;
import agentcore.tools.codex_setup : CodexSetup;
import agentcore.tools.opencode_setup : OpenCodeSetup;

/// Every agent-CLI installer, one per supported provider. Registering a new
/// provider here (and adding its adapter to `agentForModel`) is all it takes to
/// install a new agent.
AgentSetup[] allAgentSetups() @safe
{
	return [
		cast(AgentSetup) new ClaudeSetup,
		new CodexSetup,
		new OpenCodeSetup,
	];
}

/// The installer whose name matches `name`, or null when none is registered.
AgentSetup agentSetupByName(string name) @safe
{
	foreach (setup; allAgentSetups())
		if (setup.name == name)
			return setup;
	return null;
}

/// The installer for the CLI a run on `model` will use — keyed to the same
/// `agentForModel` routing that picks the adapter, so "install X" can never drift
/// from "run X". Falls back to Claude (the system default) exactly as the adapter
/// routing does.
AgentSetup agentSetupForModel(string model) @safe
{
	auto setup = agentSetupByName(agentForModel(model).name);
	return setup is null ? new ClaudeSetup : setup;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	// Selection follows agentForModel, so the installed CLI matches the adapter.
	agentSetupForModel("claude-sonnet-4-6").name.should.equal("claude");
	agentSetupForModel("").name.should.equal("claude");
	agentSetupForModel("gpt-5-codex").name.should.equal("codex");
	agentSetupForModel("o3-mini").name.should.equal("codex");
	agentSetupForModel("opencode/anthropic/claude-sonnet-4-6").name.should.equal("opencode");
}

@safe unittest
{
	allAgentSetups().length.should.equal(3);
	agentSetupByName("codex").name.should.equal("codex");
	(agentSetupByName("nope") is null).should.equal(true);
}
