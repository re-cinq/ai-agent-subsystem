module agentcore.vendors.codex.agent;

import agentcore.vendors.base.agent : Agent;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.enums : PermissionMode;

/// OpenAI Codex CLI adapter: `codex exec --json …`. Codex governs tool access
/// through its sandbox/approval model rather than per-tool flags, so the recipe's
/// allow/deny lists do not map to arguments here.
final class CodexAgent : Agent
{
	/// Un-hide the interface's no-conversation convenience overload, which this
	/// class's own `command` would otherwise shadow.
	alias command = Agent.command;

	override string name() const @safe
	{
		return "codex";
	}

	/// Codex assigns its own session id — `codex exec` has no pin flag, only the
	/// `resume` subcommand. Continuity therefore needs the id read back from the run.
	override string[] pinConversationArgs(string) const @safe
	{
		return [];
	}

	override string stateDir() const @safe
	{
		return ".codex/sessions";
	}

	override string[] command(in AgentDefinitionSpec recipe, string renderedPrompt,
		string conversationId) const @safe
	{
		// `resume` is a SUBCOMMAND here, not a flag, and it takes the prompt as a
		// positional rather than after `--` (`codex exec resume <id> <prompt>`) —
		// the reason the conversation id is a parameter of command() instead of an
		// argv fragment a caller could append.
		string[] cmd = conversationId.length
			? ["codex", "exec", "resume", conversationId, "--json"]
			: ["codex", "exec", "--json"];
		if (recipe.model.length)
			cmd ~= ["--model", recipe.model];
		if (recipe.permissionMode == PermissionMode.bypass)
			cmd ~= "--dangerously-bypass-approvals-and-sandbox";
		cmd ~= conversationId.length ? [renderedPrompt] : ["--", renderedPrompt];
		return cmd;
	}
}

version (unittest) import fluent.asserts;

@safe unittest
{
	AgentDefinitionSpec recipe;
	recipe.model = "gpt-5-codex";
	const cmd = (new CodexAgent).command(recipe, "Refactor");
	cmd[0].should.equal("codex");
	cmd[1].should.equal("exec");
	cmd.should.contain("--json");
	cmd.should.contain("gpt-5-codex");
	cmd.should.not.contain("--dangerously-bypass-approvals-and-sandbox"); // auto is the default
	cmd[$ - 2].should.equal("--"); // prompt fenced behind end-of-options
	cmd[$ - 1].should.equal("Refactor");
}

@safe unittest
{
	// #136: a leading-dash prompt is data, not a codex flag — the -- fence guarantees it.
	AgentDefinitionSpec recipe;
	const cmd = (new CodexAgent).command(recipe, "--help");
	cmd[$ - 2].should.equal("--");
	cmd[$ - 1].should.equal("--help");
}

@safe unittest
{
	// Explicit bypass adds the sandbox-skip flag.
	AgentDefinitionSpec recipe;
	recipe.permissionMode = PermissionMode.bypass;
	(new CodexAgent).command(recipe, "p").should.contain("--dangerously-bypass-approvals-and-sandbox");
}

@safe unittest
{
	// `resume` is a subcommand and the prompt is a positional — NOT after `--`.
	AgentDefinitionSpec recipe;
	const cmd = (new CodexAgent).command(recipe, "next turn", "sess-1");
	cmd[0 .. 4].should.equal(["codex", "exec", "resume", "sess-1"]);
	cmd[$ - 1].should.equal("next turn");
	cmd.should.not.contain("--");
}

@safe unittest
{
	// A fresh run keeps the original shape, prompt after the terminator.
	AgentDefinitionSpec recipe;
	const cmd = (new CodexAgent).command(recipe, "p", "");
	cmd[0 .. 3].should.equal(["codex", "exec", "--json"]);
	cmd[$ - 2 .. $].should.equal(["--", "p"]);
}

@safe unittest
{
	// Date/timestamp-partitioned paths mean the state is addressed as a directory.
	(new CodexAgent).stateDir.should.equal(".codex/sessions");
}

@safe unittest
{
	// Codex has no pin flag — only `resume`. An empty result is how the adapter says
	// the id is assigned by the CLI, rather than pretending it can be chosen.
	(new CodexAgent).pinConversationArgs("sess-1").should.equal(cast(string[])[]);
}
