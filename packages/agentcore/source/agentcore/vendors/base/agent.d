module agentcore.vendors.base.agent;

import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;

/// The conversation wiring for one run: continue `resume`, and save this run's own
/// state as `pin`. Both optional and independent — a fresh run that still saves has a
/// pin and no resume; a vendor whose CLI cannot pin ignores the latter.
struct ConversationArgs
{
	string resume;
	string pin;
}

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
	/// `conv.resume` continues a previous run; empty starts fresh. The ADAPTER
	/// decides where it belongs, because CLIs disagree structurally: Claude appends
	/// a `--resume <id>` flag before the prompt, while Codex makes it a subcommand
	/// (`codex exec resume <id> <prompt>`). An appendable "resume args" fragment
	/// could not express both, which is why the id is a parameter here.
	string[] command(in AgentDefinitionSpec recipe, string renderedPrompt,
		in ConversationArgs conv) const @safe;

	/// Directory under `$HOME` holding this CLI's conversation state, restored and
	/// snapshotted as a WHOLE. Empty means the adapter cannot continue a run.
	///
	/// A directory rather than a file path: Codex writes
	/// `.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<timestamp>-<id>.jsonl`, so the
	/// location cannot be derived from the id alone. Snapshotting the directory also
	/// handles multi-file formats without the interface knowing any of them.
	string stateDir() const @safe;

	/// Argv that PINS this run's conversation id, so the caller knows it before the
	/// run rather than having to discover it afterwards.
	///
	/// Empty means the CLI assigns its own id: Claude accepts `--session-id <uuid>`,
	/// Codex does not — it only offers `resume`. A vendor with a state dir but no pin
	/// can resume in principle, but driving it needs the id read back out of the run,
	/// which nothing implements yet. Reporting that here keeps the gap explicit
	/// instead of silently starting fresh every round.
	string[] pinConversationArgs(string conversationId) const @safe;

	/// Convenience for callers with no conversation to continue.
	final string[] command(in AgentDefinitionSpec recipe, string renderedPrompt) const @safe
	{
		return command(recipe, renderedPrompt, ConversationArgs.init);
	}
}
