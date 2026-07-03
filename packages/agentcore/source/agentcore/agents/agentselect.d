module agentcore.agents.agentselect;

import std.algorithm.searching : startsWith, canFind;
import std.uni : toLower;

import agentcore.agents.agent : Agent;
import agentcore.agents.claude_agent : ClaudeAgent;
import agentcore.agents.codex_agent : CodexAgent;
import agentcore.agents.opencode_agent : OpenCodeAgent;

/// Choose the agent adapter from a model id. An explicit `opencode` / `opencode/…`
/// id maps to OpenCode; the GPT / o-series / codex family maps to Codex; Claude
/// models and the empty or unrecognized case map to Claude (the system default).
/// OpenCode is checked first so an `opencode/openai/gpt-…` id routes to OpenCode
/// rather than matching the Codex `gpt` rule.
Agent agentForModel(string model) @safe
{
	const m = model.toLower;
	if (m.canFind("opencode"))
		return new OpenCodeAgent;
	if (m.canFind("codex") || m.startsWith("gpt") || m.startsWith("o1")
		|| m.startsWith("o3") || m.startsWith("o4"))
		return new CodexAgent;
	return new ClaudeAgent;
}

version (unittest) import fluent.asserts;

unittest
{
	agentForModel("claude-sonnet-4-6").name.should.equal("claude");
	agentForModel("").name.should.equal("claude");
	agentForModel("something-weird").name.should.equal("claude");
	agentForModel("gpt-5-codex").name.should.equal("codex");
	agentForModel("gpt-4.1").name.should.equal("codex");
	agentForModel("o3-mini").name.should.equal("codex");
	agentForModel("opencode").name.should.equal("opencode");
	agentForModel("opencode/anthropic/claude-sonnet-4-6").name.should.equal("opencode");
	agentForModel("opencode/openai/gpt-4.1").name.should.equal("opencode"); // OpenCode wins over the gpt rule
}
