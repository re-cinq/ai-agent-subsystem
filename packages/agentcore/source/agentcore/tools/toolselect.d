module agentcore.tools.toolselect;

import agentcore.tools.agent_tool : AgentTool;
import agentcore.tools.git_tool : GitTool;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.conversation_tool : ConversationTool;
import agentcore.tools.hooks_tool : HooksTool;
import agentcore.tools.skills_tool : SkillsTool;
import agentcore.tools.supervisor_tool : SupervisorTool;
import agentcore.tools.tool : Tool;
import agentcore.vendors.select : agentSetupForModel;

/// Every provisioning tool for this run, in execution order: stage the supervisor
/// into the bundle first, then git (get the code down) before installing a CLI,
/// then the agent CLI the run's model routes to. Each decides for itself whether a
/// given run needs it (see `Tool.steps`); the agent CLI is selected from the model
/// so the installed CLI always matches the adapter that will run.
Tool[] allTools(in InitContext ctx) @safe
{
	Tool[] tools;
	tools ~= new SupervisorTool;
	tools ~= new GitTool;
	auto setup = agentSetupForModel(ctx.model);
	tools ~= new AgentTool(setup);
	// After git (so a repo's own .claude/skills is cloned) and the CLI: stage the
	// run's skills + base settings into HOME for claude to auto-load.
	tools ~= new SkillsTool;
	// Then the registry's hook bundle for the vendor the model routes to, after
	// skills so its vendor-native config wins over the flat settings.json.
	tools ~= new HooksTool(setup.name);
	// Last: restore a previous run's state into the vendor's own state dir, after the
	// CLI is installed (so the directory it owns exists) and after skills, which write
	// elsewhere under the same $HOME.
	tools ~= new ConversationTool;
	return tools;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	InitContext ctx;
	ctx.model = "claude-sonnet-4-6";
	auto tools = allTools(ctx);
	tools.length.should.equal(6);
	tools[0].name.should.equal("supervisor");
	tools[1].name.should.equal("git");
	tools[2].name.should.equal("claude");
	tools[3].name.should.equal("skills");
	tools[4].name.should.equal("hooks");
	tools[5].name.should.equal("conversation");

	// The hook bundle is keyed to the same vendor the CLI install routes to.
	import std.algorithm.searching : canFind;

	InitContext withSource;
	withSource.model = "gpt-5-codex";
	withSource.skillsSource = "https://registry.example/skills";
	allTools(withSource)[4].steps(withSource)[0][2].canFind("/hooks/codex.tar.gz")
		.should.equal(true);

	// The agent tool follows the model's adapter routing.
	ctx.model = "gpt-5-codex";
	allTools(ctx)[2].name.should.equal("codex");
	ctx.model = "opencode";
	allTools(ctx)[2].name.should.equal("opencode");
}
