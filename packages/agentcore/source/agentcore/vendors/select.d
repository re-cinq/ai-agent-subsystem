module agentcore.vendors.select;

import std.algorithm.searching : startsWith, canFind;
import std.uni : toLower;

import agentcore.vendors.base.agent : Agent;
import agentcore.vendors.base.setup : AgentSetup;
import agentcore.vendors.claude.agent : ClaudeAgent;
import agentcore.vendors.claude.setup : ClaudeSetup;
import agentcore.vendors.codex.agent : CodexAgent;
import agentcore.vendors.codex.setup : CodexSetup;
import agentcore.vendors.exec.agent : ExecAgent;
import agentcore.vendors.exec.setup : ExecSetup;
import agentcore.vendors.opencode.agent : OpenCodeAgent;
import agentcore.vendors.opencode.setup : OpenCodeSetup;

/// Choose the agent adapter from a model id. The literal `exec` id maps to the
/// non-LLM command runner (station recipes); an explicit `opencode` / `opencode/…`
/// id maps to OpenCode; the GPT / o-series / codex family maps to Codex; Claude
/// models and the empty or unrecognized case map to Claude (the system default).
/// OpenCode is checked first so an `opencode/openai/gpt-…` id routes to OpenCode
/// rather than matching the Codex `gpt` rule.
Agent agentForModel(string model) @safe
{
	const m = model.toLower;
	if (m == "exec")
		return new ExecAgent;
	if (m.canFind("opencode"))
		return new OpenCodeAgent;
	if (m.canFind("codex") || m.startsWith("gpt") || m.startsWith("o1")
		|| m.startsWith("o3") || m.startsWith("o4"))
		return new CodexAgent;
	return new ClaudeAgent;
}

/// Every agent-CLI installer, one per supported vendor. Registering a new vendor
/// here (and adding its adapter to `agentForModel`) is all it takes to install a
/// new agent.
AgentSetup[] allAgentSetups() @safe
{
	return [
		cast(AgentSetup) new ClaudeSetup,
		new CodexSetup,
		new ExecSetup,
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
	// Adapter routing.
	agentForModel("claude-sonnet-4-6").name.should.equal("claude");
	agentForModel("").name.should.equal("claude");
	agentForModel("something-weird").name.should.equal("claude");
	agentForModel("gpt-5-codex").name.should.equal("codex");
	agentForModel("gpt-4.1").name.should.equal("codex");
	agentForModel("o3-mini").name.should.equal("codex");
	agentForModel("opencode").name.should.equal("opencode");
	agentForModel("opencode/anthropic/claude-sonnet-4-6").name.should.equal("opencode");
	agentForModel("opencode/openai/gpt-4.1").name.should.equal("opencode"); // OpenCode wins over the gpt rule
	agentForModel("exec").name.should.equal("exec");
	agentForModel("EXEC").name.should.equal("exec");
	agentForModel("executive-model").name.should.equal("claude"); // exact match only, no substring
}

@safe unittest
{
	// Installer selection follows the same routing, so the installed CLI matches
	// the adapter that runs.
	agentSetupForModel("claude-sonnet-4-6").name.should.equal("claude");
	agentSetupForModel("").name.should.equal("claude");
	agentSetupForModel("gpt-5-codex").name.should.equal("codex");
	agentSetupForModel("o3-mini").name.should.equal("codex");
	agentSetupForModel("opencode/anthropic/claude-sonnet-4-6").name.should.equal("opencode");

	agentSetupForModel("exec").name.should.equal("exec");

	allAgentSetups().length.should.equal(4);
	agentSetupByName("codex").name.should.equal("codex");
	(agentSetupByName("nope") is null).should.equal(true);
}
