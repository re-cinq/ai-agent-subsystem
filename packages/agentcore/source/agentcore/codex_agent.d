module agentcore.codex_agent;

import agentcore.agent : Agent;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.enums : PermissionMode;

/// OpenAI Codex CLI adapter: `codex exec --json …`. Codex governs tool access
/// through its sandbox/approval model rather than per-tool flags, so the recipe's
/// allow/deny lists do not map to arguments here.
final class CodexAgent : Agent
{
	override string name() const @safe
	{
		return "codex";
	}

	override string[] command(in AgentDefinitionSpec recipe, string renderedPrompt) const @safe
	{
		string[] cmd = ["codex", "exec", "--json"];
		if (recipe.model.length)
			cmd ~= ["--model", recipe.model];
		if (recipe.permissionMode == PermissionMode.bypass)
			cmd ~= "--dangerously-bypass-approvals-and-sandbox";
		cmd ~= renderedPrompt;
		return cmd;
	}
}

@safe unittest
{
	import std.algorithm.searching : canFind;

	AgentDefinitionSpec recipe;
	recipe.model = "gpt-5-codex";
	const cmd = (new CodexAgent).command(recipe, "Refactor");
	assert(cmd[0] == "codex" && cmd[1] == "exec");
	assert(cmd.canFind("--json") && cmd.canFind("gpt-5-codex"));
	assert(cmd.canFind("--dangerously-bypass-approvals-and-sandbox")); // bypass is the default
	assert(cmd[$ - 1] == "Refactor");
}
