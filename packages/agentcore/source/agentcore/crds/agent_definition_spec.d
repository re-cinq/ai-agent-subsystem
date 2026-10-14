module agentcore.crds.agent_definition_spec;

import vibe.data.json : Json;

import agentcore.crds.schema;
import agentcore.crds.enums : BatchTimeoutAction, Execution, PermissionMode;
import agentcore.crds.agent_resources : AgentResources;
import agentcore.crds.output_spec : OutputSpec;
import agentcore.core.vendor : Vendor, vendorOf;

struct BatchSpec
{
	@optional @Minimum(1) @Description("Minutes to wait for the batch result before onTimeout applies.")
	int timeoutMinutes = 1440;

	@optional @Description("fail marks the Agent Failed; fallback reruns the work as a CLI Job.")
	BatchTimeoutAction onTimeout = BatchTimeoutAction.fail;

	@optional @Minimum(1) @Description("Output token ceiling (max_tokens) for the batch request.")
	long maxTokens = 16_000;
}

@Description("The reusable recipe for a coding agent task.")
struct AgentDefinitionSpec
{
	@optional @Description("Human summary for operators.")
	string description;

	@optional @Description("Model id (e.g. claude-sonnet-4-6). If omitted, the runtime default is used.")
	string model;

	@optional @Required @Description("Task template; {placeholder} tokens are filled from an Agent's parameters.")
	string prompt;

	@optional @wire("allowed_tools") string[] allowedTools;
	@optional @wire("disallowed_tools") string[] disallowedTools;
	@optional @wire("permission_mode") PermissionMode permissionMode = PermissionMode.auto_;
	@optional @wire("max_turns") @Minimum(1) int maxTurns;

	@optional Execution execution = Execution.interactive;
	@optional BatchSpec batch;

	@optional AgentResources resources;
	@optional OutputSpec output;

	@optional @wire("tool_config") @PreserveUnknownFields @Description("Raw passthrough for tool-specific knobs.")
	Json toolConfig;
}

/// Why `spec` cannot run as a batch request, or "" when it can (or is interactive).
/// A batch request is a single model call, so anything that needs the CLI harness —
/// tools, turns, a workspace, MCP, skills, a resumed conversation, watched files or
/// the non-LLM exec runner — is rejected up front with the offending field named.
string batchViolation(const AgentDefinitionSpec spec) @safe
{
	if (spec.execution != Execution.batch)
		return "";
	import std.algorithm.searching : find;
	import std.conv : to;
	import std.typecons : tuple;

	const vendor = vendorOf(spec.model);
	const unsupported = [
		tuple("allowed_tools", spec.allowedTools.length > 0),
		tuple("disallowed_tools", spec.disallowedTools.length > 0),
		tuple("max_turns", spec.maxTurns > 0),
		tuple("resources.repos", spec.resources.repos.length > 0),
		tuple("resources.mcp_servers", spec.resources.mcpServers.length > 0),
		tuple("resources.skills", spec.resources.skills.length > 0),
		tuple("resources.conversation", spec.resources.conversation.id.length > 0),
		tuple("the exec model", vendor == Vendor.exec),
		tuple(vendor.to!string ~ " models", vendor != Vendor.claude),
		tuple("output.watch", spec.output.watch.length > 0),
	].find!(rule => rule[1]);
	if (unsupported.length > 0)
		return "batch execution does not support " ~ unsupported[0][0];
	return "";
}

version (unittest) import fluent.asserts;

@safe unittest
{
	AgentDefinitionSpec.init.permissionMode.should.equal(PermissionMode.auto_);
	static assert(isRequired!(AgentDefinitionSpec.prompt));
	static assert(jsonNameOf!(AgentDefinitionSpec.allowedTools) == "allowed_tools");
	static assert(jsonNameOf!(AgentDefinitionSpec.permissionMode) == "permission_mode");
	static assert(descriptionOf!(AgentDefinitionSpec.model).length > 0);
}

unittest // batch definition using an interactive-only field returns that field's reason
{
	import agentcore.crds.conversation_ref : ConversationRef;
	import agentcore.crds.mcp_server : McpServer;
	import agentcore.crds.output_watch : OutputWatch;
	import agentcore.crds.repo_ref : RepoRef;

	AgentDefinitionSpec batchSpec(void delegate(ref AgentDefinitionSpec) @safe change) @safe
	{
		AgentDefinitionSpec spec;
		spec.execution = Execution.batch;
		change(spec);
		return spec;
	}

	const cases = [
		batchSpec((ref s) { s.allowedTools = ["Read"]; }): "batch execution does not support allowed_tools",
		batchSpec((ref s) { s.disallowedTools = ["Bash"]; }): "batch execution does not support disallowed_tools",
		batchSpec((ref s) { s.maxTurns = 3; }): "batch execution does not support max_turns",
		batchSpec((ref s) { s.resources.repos = [RepoRef()]; }): "batch execution does not support resources.repos",
		batchSpec((ref s) { s.resources.mcpServers = [McpServer()]; }): "batch execution does not support resources.mcp_servers",
		batchSpec((ref s) { s.resources.skills = ["review"]; }): "batch execution does not support resources.skills",
		batchSpec((ref s) { s.resources.conversation = ConversationRef("", "c1"); }): "batch execution does not support resources.conversation",
		batchSpec((ref s) { s.model = "exec"; }): "batch execution does not support the exec model",
		batchSpec((ref s) { s.output.watch = [OutputWatch()]; }): "batch execution does not support output.watch",
	];
	foreach (spec, reason; cases)
		batchViolation(spec).should.equal(reason);
}

unittest // batch definition with only a model and prompt and an interactive definition with tools have no violation
{
	AgentDefinitionSpec batch;
	batch.execution = Execution.batch;
	batch.model = "claude-sonnet-4-6";
	batch.prompt = "p";
	AgentDefinitionSpec interactive;
	interactive.allowedTools = ["Read"];
	[batchViolation(batch), batchViolation(interactive)].should.equal(["", ""]);
}

unittest // batch definition with model EXEC returns the exec model reason
{
	AgentDefinitionSpec spec;
	spec.execution = Execution.batch;
	spec.model = "EXEC";
	batchViolation(spec).should.equal("batch execution does not support the exec model");
}

unittest // batch definition with an opencode, codex or gemini model returns that vendor's models reason
{
	AgentDefinitionSpec spec(string model)
	{
		AgentDefinitionSpec batch;
		batch.execution = Execution.batch;
		batch.model = model;
		return batch;
	}

	[batchViolation(spec("opencode/anthropic/claude-sonnet-4")), batchViolation(spec("gpt-5-codex")),
		batchViolation(spec("gemini-2.5-pro"))].should.equal([
		"batch execution does not support opencode models",
		"batch execution does not support codex models", "batch execution does not support gemini models"
	]);
}

unittest // batch definition with an output.schema has no violation
{
	import vibe.data.json : parseJsonString;

	AgentDefinitionSpec spec;
	spec.execution = Execution.batch;
	spec.output.schema = parseJsonString(`{"type":"object"}`);
	batchViolation(spec).should.equal("");
}
