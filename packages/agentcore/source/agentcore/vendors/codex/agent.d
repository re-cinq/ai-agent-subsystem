module agentcore.vendors.codex.agent;

import agentcore.vendors.base.agent : Agent;
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
	cmd.should.contain("--dangerously-bypass-approvals-and-sandbox"); // bypass is the default
	cmd[$ - 1].should.equal("Refactor");
}
