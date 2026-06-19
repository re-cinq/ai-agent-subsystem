module agentcore.crds;

import std.json : JSONValue;

import agentcore.types : Phase;
import agentcore.schema;

// Typed model of the three Custom Resources (agents.re-cinq.com/v1alpha1).
// Field names are idiomatic D; @Json carries the wire name where it differs
// (snake_case fields and the D keywords `ref`/`template`). @Description,
// @Required, @Minimum and @PreserveUnknownFields carry the rest of the schema
// metadata that D types cannot express on their own.

/// Subset of Kubernetes ObjectMeta these resources use.
struct ObjectMeta
{
	string name;
	string generateName;
	string namespace;
	string uid;
	string[string] labels;
	string[string] annotations;
}

// ---------------------------------------------------------------------------
// AgentDefinition — the recipe.
// ---------------------------------------------------------------------------

enum PermissionMode : string
{
	auto_ = "auto",
	bypass = "bypass",
}

enum McpTransport : string
{
	stdio = "stdio",
	http = "http",
	sse = "sse",
}

enum OutputFormat : string
{
	text = "text",
	json = "json",
	streamJson = "stream-json",
}

enum SelectEvent : string
{
	toolCall = "tool_call",
	message = "message",
	toolResult = "tool_result",
	result = "result",
	usage = "usage",
}

enum SelectRole : string
{
	assistant = "assistant",
	user = "user",
}

enum SinkType : string
{
	stdout = "stdout",
	http = "http",
	file = "file",
}

struct EnvVar
{
	@Required string name;
	@Required string value;
}

struct SecretRef
{
	@Required @Description("Environment variable name to expose the secret as.")
	string name;

	@Required @Json("ref") @Description("Allowlisted secret-store key.")
	string ref_;
}

struct McpServer
{
	@Required string name;
	@Required McpTransport transport;
	string command;
	string[] args;
	string url;
	@Json("headers_secret") string headersSecret;
}

struct RepoRef
{
	@Required string name;
	@Required string url;
	@Json("ref") string ref_;
	string path;
	@Json("token_secret") string tokenSecret;
}

struct AgentResources
{
	EnvVar[] env;
	SecretRef[] secrets;
	@Json("mcp_servers") McpServer[] mcpServers;
	RepoRef[] repos;
}

struct OutputSelector
{
	@Required SelectEvent event;
	string tool;
	SelectRole role;
	string contains;
}

struct OutputSink
{
	@Required SinkType type;
	string url;
	@Json("headers_secret") string headersSecret;
	string path;
}

struct OutputSpec
{
	OutputFormat format;

	@PreserveUnknownFields @Description("JSON Schema validating the result.")
	JSONValue schema;

	OutputSelector[] select;
	OutputSink[] sinks;
}

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

struct AgentDefinition
{
	string apiVersion = "agents.re-cinq.com/v1alpha1";
	string kind = "AgentDefinition";
	ObjectMeta metadata;
	AgentDefinitionSpec spec;
}

// ---------------------------------------------------------------------------
// Station — the runtime template.
// ---------------------------------------------------------------------------

@Description("The runtime template that pairs a recipe with a Pod template.")
struct StationSpec
{
	@Required @Description("Name of the AgentDefinition this Station runs.")
	string agentDefRef;

	@Minimum(1) @Description("Wall-clock limit per run; becomes the Job's activeDeadlineSeconds.")
	int deadlineMinutes = 30;

	@Minimum(0) int successfulRunsHistoryLimit = 3;
	@Minimum(0) int failedRunsHistoryLimit = 3;

	@Required @Json("template") @PreserveUnknownFields
	@Description("Standard Kubernetes PodTemplateSpec; the container named \"agent\" is wired with the recipe.")
	JSONValue template_;
}

struct Station
{
	string apiVersion = "agents.re-cinq.com/v1alpha1";
	string kind = "Station";
	ObjectMeta metadata;
	StationSpec spec;
}

// ---------------------------------------------------------------------------
// Agent — one run.
// ---------------------------------------------------------------------------

@Description("One run of a recipe in a Station.")
struct AgentSpec
{
	@Required @Description("The Station to run in (which selects the recipe).")
	string stationRef;

	@Description("External id for correlation.")
	string taskId;

	@Description("GitHub repo in owner/name form.")
	string targetRepo;

	string branch;

	@Description("Per-run values; fill the prompt {placeholder} tokens and pass to the agent.")
	string[string] parameters;
}

struct AgentStatus
{
	Phase phase;
	string jobName;
	@Description("RFC3339 timestamp when the run began.") string startedAt;
	@Description("RFC3339 timestamp when the run ended.") string completedAt;
	int exitCode;
	string output;
	string failureReason;
	string prUrl;
}

struct Agent
{
	string apiVersion = "agents.re-cinq.com/v1alpha1";
	string kind = "Agent";
	ObjectMeta metadata;
	AgentSpec spec;
	AgentStatus status;
}

// ---------------------------------------------------------------------------
// The UDA metadata is reachable at compile time (foundation for a CRD
// generator). These checks double as documentation of the attribute model.
// ---------------------------------------------------------------------------

@safe unittest
{
	// Defaults declared with D primitives.
	StationSpec s;
	assert(s.deadlineMinutes == 30 && s.successfulRunsHistoryLimit == 3);
	assert(AgentDefinitionSpec.init.permissionMode == PermissionMode.bypass);

	// Enum values match the CRD wire strings.
	assert(cast(string) PermissionMode.auto_ == "auto");
	assert(cast(string) OutputFormat.streamJson == "stream-json");
	assert(cast(string) SelectEvent.toolResult == "tool_result");
}

@safe unittest
{
	// Wire names: snake_case and keyword fields are remapped, others fall through.
	static assert(jsonNameOf!(AgentDefinitionSpec.allowedTools) == "allowed_tools");
	static assert(jsonNameOf!(AgentDefinitionSpec.permissionMode) == "permission_mode");
	static assert(jsonNameOf!(StationSpec.template_) == "template");
	static assert(jsonNameOf!(SecretRef.ref_) == "ref");
	static assert(jsonNameOf!(StationSpec.agentDefRef) == "agentDefRef");

	// Required flags and descriptions are readable.
	static assert(isRequired!(StationSpec.agentDefRef));
	static assert(!isRequired!(StationSpec.deadlineMinutes));
	static assert(descriptionOf!(AgentDefinitionSpec.model).length > 0);
}
