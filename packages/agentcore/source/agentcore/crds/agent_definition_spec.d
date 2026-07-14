module agentcore.crds.agent_definition_spec;

import vibe.data.json : Json;

import agentcore.crds.schema;
import agentcore.crds.enums : PermissionMode;
import agentcore.crds.agent_resources : AgentResources;
import agentcore.crds.output_spec : OutputSpec;

@Description("The reusable recipe for a coding agent task.")
struct AgentDefinitionSpec
{
	@optional @Description("Human summary for operators.")
	string description;

	@optional @Description("Model id (e.g. claude-sonnet-4-6). If omitted, the runtime default is used.")
	string model;

	@optional @Description("Task template; {placeholder} tokens are filled from an Agent's parameters.")
	string prompt;

	@optional @wire("allowed_tools") string[] allowedTools;
	@optional @wire("disallowed_tools") string[] disallowedTools;
	@optional @wire("permission_mode") PermissionMode permissionMode = PermissionMode.auto_;
	@optional @wire("max_turns") @Minimum(1) int maxTurns;

	@optional AgentResources resources;
	@optional OutputSpec output;

	@optional @wire("tool_config") @PreserveUnknownFields @Description("Raw passthrough for tool-specific knobs.")
	Json toolConfig;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	AgentDefinitionSpec.init.permissionMode.should.equal(PermissionMode.auto_);
	static assert(jsonNameOf!(AgentDefinitionSpec.allowedTools) == "allowed_tools");
	static assert(jsonNameOf!(AgentDefinitionSpec.permissionMode) == "permission_mode");
	static assert(descriptionOf!(AgentDefinitionSpec.model).length > 0);
}
