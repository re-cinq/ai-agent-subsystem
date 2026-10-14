module agentcore.vendors.select;

public import agentcore.core.vendor : Vendor, vendorOf;

import agentcore.vendors.base.agent : Agent;
import agentcore.vendors.base.setup : AgentSetup;
import agentcore.vendors.claude.agent : ClaudeAgent;
import agentcore.vendors.claude.setup : ClaudeSetup;
import agentcore.vendors.codex.agent : CodexAgent;
import agentcore.vendors.codex.setup : CodexSetup;
import agentcore.vendors.exec.agent : ExecAgent;
import agentcore.vendors.exec.setup : ExecSetup;
import agentcore.vendors.gemini.agent : GeminiAgent;
import agentcore.vendors.gemini.setup : GeminiSetup;
import agentcore.vendors.opencode.agent : OpenCodeAgent;
import agentcore.vendors.opencode.setup : OpenCodeSetup;

/// Choose the agent adapter for a model id's vendor.
Agent agentForModel(string model) @safe
{
	final switch (vendorOf(model))
	{
	case Vendor.claude:
		return new ClaudeAgent;
	case Vendor.codex:
		return new CodexAgent;
	case Vendor.exec:
		return new ExecAgent;
	case Vendor.gemini:
		return new GeminiAgent;
	case Vendor.opencode:
		return new OpenCodeAgent;
	}
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
		new GeminiSetup,
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
/// `vendorOf` classification that picks the adapter (each installer is named after its
/// vendor), so "install X" can never drift from "run X".
AgentSetup agentSetupForModel(string model) @safe
{
	import std.conv : to;

	auto setup = agentSetupByName(vendorOf(model).to!string);
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
	agentForModel("gemini-1.5-pro").name.should.equal("gemini");
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
	agentSetupForModel("gemini-2.0-flash").name.should.equal("gemini");

	agentSetupForModel("exec").name.should.equal("exec");

	allAgentSetups().length.should.equal(5);
	agentSetupByName("codex").name.should.equal("codex");
	agentSetupByName("gemini").name.should.equal("gemini");
	(agentSetupByName("nope") is null).should.equal(true);
}
