module agentcore.tools.toolselect;

import agentcore.tools.agent_tool : AgentTool;
import agentcore.tools.agentsetupselect : agentSetupForModel;
import agentcore.tools.git_tool : GitTool;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.supervisor_tool : SupervisorTool;
import agentcore.tools.tool : Tool;

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
	tools ~= new AgentTool(agentSetupForModel(ctx.model));
	return tools;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	InitContext ctx;
	ctx.model = "claude-sonnet-4-6";
	auto tools = allTools(ctx);
	tools.length.should.equal(3);
	tools[0].name.should.equal("supervisor");
	tools[1].name.should.equal("git");
	tools[2].name.should.equal("claude");

	// The agent tool follows the model's adapter routing.
	ctx.model = "gpt-5-codex";
	allTools(ctx)[2].name.should.equal("codex");
	ctx.model = "opencode";
	allTools(ctx)[2].name.should.equal("opencode");
}
