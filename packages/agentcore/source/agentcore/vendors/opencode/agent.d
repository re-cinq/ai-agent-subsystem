module agentcore.vendors.opencode.agent;

import std.algorithm.searching : startsWith;

import agentcore.vendors.base.agent : Agent;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;

/// OpenCode CLI adapter: `opencode run --format json …`. `--format json` emits the
/// raw JSON event stream the supervisor forwards to its sinks. OpenCode governs
/// tool access through its own permission model rather than per-tool flags, so the
/// recipe's allow/deny lists do not map to arguments here.
final class OpenCodeAgent : Agent
{
	override string name() const @safe
	{
		return "opencode";
	}

	override string[] command(in AgentDefinitionSpec recipe, string renderedPrompt) const @safe
	{
		string[] cmd = ["opencode", "run", "--format", "json"];
		const model = opencodeModel(recipe.model);
		if (model.length)
			cmd ~= ["--model", model];
		cmd ~= renderedPrompt;
		return cmd;
	}
}

/// The provider/model OpenCode's `--model` expects, recovered from the routing
/// id: `opencode/<provider>/<model>` yields `<provider>/<model>`, while a bare
/// `opencode` (the routing signal with no model) means "use OpenCode's default".
private string opencodeModel(string model) @safe pure
{
	enum prefix = "opencode/";
	if (model.startsWith(prefix))
		return model[prefix.length .. $];
	if (model == "opencode")
		return "";
	return model;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	AgentDefinitionSpec recipe;
	recipe.model = "opencode/anthropic/claude-sonnet-4-6";
	const cmd = (new OpenCodeAgent).command(recipe, "Refactor");
	cmd[0 .. 4].should.equal(["opencode", "run", "--format", "json"]);
	cmd.should.contain("--model");
	cmd.should.contain("anthropic/claude-sonnet-4-6"); // the "opencode/" prefix is stripped
	cmd[$ - 1].should.equal("Refactor");
}

@safe unittest
{
	// A bare "opencode" routes to the adapter but passes no --model (OpenCode's default).
	AgentDefinitionSpec recipe;
	recipe.model = "opencode";
	const cmd = (new OpenCodeAgent).command(recipe, "p");
	cmd.should.not.contain("--model");
	cmd[$ - 1].should.equal("p");
}
