module agentcore.toolselect;

import agentcore.claude_tool : ClaudeTool;
import agentcore.git_tool : GitTool;
import agentcore.tool : Tool;

/// Every provisioning tool, in execution order: git first (get the code down
/// before installing a CLI), then claude. Each decides for itself whether a given
/// run needs it (see `Tool.steps`).
Tool[] allTools() @safe
{
	Tool[] tools;
	tools ~= new GitTool;
	tools ~= new ClaudeTool;
	return tools;
}

unittest
{
	auto tools = allTools();
	assert(tools.length == 2);
	assert(tools[0].name == "git");
	assert(tools[1].name == "claude");
}
