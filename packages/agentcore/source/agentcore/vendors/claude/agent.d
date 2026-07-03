module agentcore.vendors.claude.agent;

import std.conv : to;

import agentcore.vendors.base.agent : Agent;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.enums : PermissionMode;
import agentcore.core.env : defaultModel;

/// Claude Code CLI adapter: maps the recipe to `claude --print --output-format
/// stream-json …`. `bypass` permission mode skips the permission prompts; `auto`
/// passes the recipe's allow/deny tool lists through.
final class ClaudeAgent : Agent
{
	override string name() const @safe
	{
		return "claude";
	}

	override string[] command(in AgentDefinitionSpec recipe, string renderedPrompt) const @safe
	{
		string[] cmd = [
			"claude",
			"--print",
			"--verbose",
			"--output-format", "stream-json",
			"--model", recipe.model.length ? recipe.model : defaultModel,
		];

		if (recipe.permissionMode == PermissionMode.bypass)
			cmd ~= "--dangerously-skip-permissions";
		else
		{
			foreach (tool; recipe.allowedTools)
				cmd ~= ["--allowedTools", tool];
			foreach (tool; recipe.disallowedTools)
				cmd ~= ["--disallowedTools", tool];
		}

		if (recipe.maxTurns > 0)
			cmd ~= ["--max-turns", recipe.maxTurns.to!string];

		cmd ~= ["--", renderedPrompt];
		return cmd;
	}
}

version (unittest) import fluent.asserts;

@safe unittest
{
	AgentDefinitionSpec recipe;
	recipe.model = "claude-sonnet-4-6";
	recipe.permissionMode = PermissionMode.auto_;
	recipe.allowedTools = ["Read", "Edit"];
	recipe.disallowedTools = ["Bash(rm *)"];
	recipe.maxTurns = 40;

	const cmd = (new ClaudeAgent).command(recipe, "Fix it");
	cmd[0].should.equal("claude");
	cmd.should.contain("claude-sonnet-4-6");
	cmd.should.contain("--allowedTools");
	cmd.should.contain("Read");
	cmd.should.contain("Edit");
	cmd.should.contain("--disallowedTools");
	cmd.should.contain("Bash(rm *)");
	cmd.should.contain("--max-turns");
	cmd.should.contain("40");
	cmd.should.not.contain("--dangerously-skip-permissions");
	cmd[$ - 2].should.equal("--");
	cmd[$ - 1].should.equal("Fix it");
}

@safe unittest
{
	// Defaults: permissionMode is bypass, empty model -> default.
	AgentDefinitionSpec recipe;
	const cmd = (new ClaudeAgent).command(recipe, "p");
	cmd.should.contain("--dangerously-skip-permissions");
	cmd.should.contain(defaultModel);
	cmd.should.not.contain("--allowedTools");
}
