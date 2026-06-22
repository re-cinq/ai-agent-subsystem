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

version (unittest) import fluent.asserts;

@safe unittest
{
	(cast(string) PermissionMode.auto_).should.equal("auto");
	(cast(string) OutputFormat.streamJson).should.equal("stream-json");
	(cast(string) SelectEvent.toolResult).should.equal("tool_result");
}
