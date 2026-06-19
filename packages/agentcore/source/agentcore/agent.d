module agentcore.agent;

import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;

/// A pluggable coding-agent CLI — Claude Code, OpenAI Codex, or any other.
/// An adapter maps the recipe (and the already-rendered prompt) to the argv to
/// spawn; the spawned process must emit newline-delimited JSON events on stdout,
/// which the supervisor streams to its output sinks. New providers are added by
/// implementing this interface — nothing else in the system changes.
interface Agent
{
	/// The adapter identifier (e.g. "claude", "codex").
	string name() const @safe;

	/// The argv to spawn for `recipe`, using `renderedPrompt` as the task prompt.
	/// `recipe.prompt` is a template, so the caller fills it first and passes the
	/// result here.
	string[] command(in AgentDefinitionSpec recipe, string renderedPrompt) const @safe;
}
