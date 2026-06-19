module agentcore.agentselect;

import std.algorithm.searching : startsWith, canFind;
import std.uni : toLower;

import agentcore.agent : Agent;
import agentcore.claude_agent : ClaudeAgent;
import agentcore.codex_agent : CodexAgent;

/// Choose the agent adapter from a model id. The GPT / o-series / codex family
/// maps to Codex; Claude models and the empty or unrecognized case map to Claude
/// (the system default).
Agent agentForModel(string model)
{
	const m = model.toLower;
	if (m.canFind("codex") || m.startsWith("gpt") || m.startsWith("o1")
		|| m.startsWith("o3") || m.startsWith("o4"))
		return new CodexAgent;
	return new ClaudeAgent;
}

unittest
{
	assert(agentForModel("claude-sonnet-4-6").name == "claude");
	assert(agentForModel("").name == "claude");
	assert(agentForModel("something-weird").name == "claude");
	assert(agentForModel("gpt-5-codex").name == "codex");
	assert(agentForModel("gpt-4.1").name == "codex");
	assert(agentForModel("o3-mini").name == "codex");
}
