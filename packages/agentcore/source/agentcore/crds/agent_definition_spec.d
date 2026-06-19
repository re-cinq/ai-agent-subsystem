module agentcore.crds.agent_definition_spec;

import std.json : JSONValue;

import agentcore.schema;
import agentcore.crds.enums : PermissionMode;
import agentcore.crds.agent_resources : AgentResources;
import agentcore.crds.output_spec : OutputSpec;

@Description("The reusable recipe for a coding agent task.")
struct AgentDefinitionSpec
{
	@Description("Human summary for operators.")
	string description;

	@Description("Model id (e.g. claude-sonnet-4-6). If omitted, the runtime default is used.")
	string model;

	@Description("Task template; {placeholder} tokens are filled from an Agent's parameters.")
	string prompt;

	@Json("allowed_tools") string[] allowedTools;
	@Json("disallowed_tools") string[] disallowedTools;
	@Json("permission_mode") PermissionMode permissionMode = PermissionMode.bypass;
	@Json("max_turns") @Minimum(1) int maxTurns;

	AgentResources resources;
	OutputSpec output;

	@Json("tool_config") @PreserveUnknownFields @Description("Raw passthrough for tool-specific knobs.")
	JSONValue toolConfig;
}

@safe unittest
{
	assert(AgentDefinitionSpec.init.permissionMode == PermissionMode.bypass);
	static assert(jsonNameOf!(AgentDefinitionSpec.allowedTools) == "allowed_tools");
	static assert(jsonNameOf!(AgentDefinitionSpec.permissionMode) == "permission_mode");
	static assert(descriptionOf!(AgentDefinitionSpec.model).length > 0);
}
