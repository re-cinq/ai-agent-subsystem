module agentcore.claude_agent;

import std.conv : to;

import agentcore.agent : Agent;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.enums : PermissionMode;
import agentcore.env : defaultModel;

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

@safe unittest
{
	import std.algorithm.searching : canFind;

	AgentDefinitionSpec recipe;
	recipe.model = "claude-sonnet-4-6";
	recipe.permissionMode = PermissionMode.auto_;
	recipe.allowedTools = ["Read", "Edit"];
	recipe.disallowedTools = ["Bash(rm *)"];
	recipe.maxTurns = 40;

	const cmd = (new ClaudeAgent).command(recipe, "Fix it");
	assert(cmd[0] == "claude");
	assert(cmd.canFind("claude-sonnet-4-6"));
	assert(cmd.canFind("--allowedTools") && cmd.canFind("Read") && cmd.canFind("Edit"));
	assert(cmd.canFind("--disallowedTools") && cmd.canFind("Bash(rm *)"));
	assert(cmd.canFind("--max-turns") && cmd.canFind("40"));
	assert(!cmd.canFind("--dangerously-skip-permissions"));
	assert(cmd[$ - 2] == "--" && cmd[$ - 1] == "Fix it");
}

@safe unittest
{
	import std.algorithm.searching : canFind;

	// Defaults: permissionMode is bypass, empty model -> default.
	AgentDefinitionSpec recipe;
	const cmd = (new ClaudeAgent).command(recipe, "p");
	assert(cmd.canFind("--dangerously-skip-permissions"));
	assert(cmd.canFind(defaultModel));
	assert(!cmd.canFind("--allowedTools"));
}
