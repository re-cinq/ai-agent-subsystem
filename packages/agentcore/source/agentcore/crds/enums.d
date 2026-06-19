module agentcore.crds.enums;

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

@safe unittest
{
	assert(cast(string) PermissionMode.auto_ == "auto");
	assert(cast(string) OutputFormat.streamJson == "stream-json");
	assert(cast(string) SelectEvent.toolResult == "tool_result");
}
