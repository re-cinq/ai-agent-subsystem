module agentcore.tools.toolselect;

import agentcore.tools.claude_tool : ClaudeTool;
import agentcore.tools.git_tool : GitTool;
import agentcore.tools.supervisor_tool : SupervisorTool;
import agentcore.tools.tool : Tool;

/// Every provisioning tool, in execution order: stage the supervisor into the
/// bundle first, then git (get the code down) before installing a CLI, then
/// claude. Each decides for itself whether a given run needs it (see `Tool.steps`).
Tool[] allTools() @safe
{
	Tool[] tools;
	tools ~= new SupervisorTool;
	tools ~= new GitTool;
	tools ~= new ClaudeTool;
	return tools;
}

unittest
{
	auto tools = allTools();
	assert(tools.length == 3);
	assert(tools[0].name == "supervisor");
	assert(tools[1].name == "git");
	assert(tools[2].name == "claude");
}
