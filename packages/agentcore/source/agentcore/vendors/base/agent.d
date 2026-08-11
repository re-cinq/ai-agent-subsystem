module agentcore.vendors.base.agent;

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
	///
	/// `conversationId` continues a previous run; empty starts fresh. The ADAPTER
	/// decides where it belongs, because CLIs disagree structurally: Claude appends
	/// a `--resume <id>` flag before the prompt, while Codex makes it a subcommand
	/// (`codex exec resume <id> <prompt>`). An appendable "resume args" fragment
	/// could not express both, which is why the id is a parameter here.
	string[] command(in AgentDefinitionSpec recipe, string renderedPrompt,
		string conversationId) const @safe;

	/// Directory under `$HOME` holding this CLI's conversation state, restored and
	/// snapshotted as a WHOLE. Empty means the adapter cannot continue a run.
	///
	/// A directory rather than a file path: Codex writes
	/// `.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<timestamp>-<id>.jsonl`, so the
	/// location cannot be derived from the id alone. Snapshotting the directory also
	/// handles multi-file formats without the interface knowing any of them.
	string stateDir() const @safe;

	/// Convenience for callers with no conversation to continue.
	final string[] command(in AgentDefinitionSpec recipe, string renderedPrompt) const @safe
	{
		return command(recipe, renderedPrompt, "");
	}
}
