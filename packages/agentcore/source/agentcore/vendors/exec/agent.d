module agentcore.vendors.exec.agent;

import std.exception : enforce;

import vibe.data.json : Json;

import agentcore.vendors.base.agent : Agent;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;

/// Non-LLM command runner ("station" recipes): spawns the argv listed in the
/// recipe's `tool_config.command` with the rendered prompt appended as the final
/// argument. The station process must honor the same NDJSON stdout protocol as
/// the LLM CLIs — in particular it ends with a claude-style
/// `{"type":"result", ...}` line, which the supervisor's terminal detection
/// already recognizes, so no supervisor changes are needed for exec runs.
final class ExecAgent : Agent
{
	override string name() const @safe
	{
		return "exec";
	}

	override string[] command(in AgentDefinitionSpec recipe, string renderedPrompt) const @safe
	{
		const toolConfig = recipe.toolConfig;
		enforce(toolConfig.type == Json.Type.object && "command" in toolConfig,
			"exec recipe needs tool_config.command (the argv to spawn)");
		const commandJson = toolConfig["command"];
		enforce(commandJson.type == Json.Type.array && commandJson.length > 0,
			"exec recipe tool_config.command must be a non-empty array of strings");

		string[] cmd;
		foreach (i; 0 .. commandJson.length)
		{
			const entry = commandJson[i];
			enforce(entry.type == Json.Type.string,
				"exec recipe tool_config.command entries must be strings");
			cmd ~= entry.get!string;
		}
		cmd ~= renderedPrompt;
		return cmd;
	}
}

version (unittest) import fluent.asserts;
version (unittest) import std.exception : assertThrown;
version (unittest) import vibe.data.json : parseJsonString;

@safe unittest
{
	AgentDefinitionSpec recipe;
	recipe.toolConfig = parseJsonString(`{"command": ["lore-station", "validate"]}`);

	const cmd = (new ExecAgent).command(recipe, `{"node_id":"validate"}`);
	cmd.should.equal(["lore-station", "validate", `{"node_id":"validate"}`]);
}

@safe unittest
{
	// Missing / malformed tool_config.command is a recipe configuration error.
	AgentDefinitionSpec noConfig;
	assertThrown((new ExecAgent).command(noConfig, "p"));

	AgentDefinitionSpec emptyCommand;
	emptyCommand.toolConfig = parseJsonString(`{"command": []}`);
	assertThrown((new ExecAgent).command(emptyCommand, "p"));

	AgentDefinitionSpec nonStringEntry;
	nonStringEntry.toolConfig = parseJsonString(`{"command": ["lore-station", 7]}`);
	assertThrown((new ExecAgent).command(nonStringEntry, "p"));
}
