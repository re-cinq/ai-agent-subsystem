module agentcore.agentselect;

import std.algorithm.searching : startsWith, canFind;
import std.uni : toLower;

import agentcore.agent : Agent;
import agentcore.claude_agent : ClaudeAgent;
import agentcore.codex_agent : CodexAgent;

/// Choose the agent adapter from a model id. The GPT / o-series / codex family
/// maps to Codex; Claude models and the empty or unrecognized case map to Claude
/// (the system default).
Agent agentForModel(string model) @safe
{
	const m = model.toLower;
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
}
