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

/// How a Station handles a new run while at its concurrent-run limit, mirroring
/// CronJob: Allow queues (subject to maxConcurrentRuns), Forbid caps at one, and
/// Replace cancels the oldest run to start the new one.
enum ConcurrencyPolicy : string
{
	allow = "Allow",
	forbid = "Forbid",
	replace = "Replace",
}

version (unittest) import fluent.asserts;

@safe unittest
{
	(cast(string) PermissionMode.auto_).should.equal("auto");
	(cast(string) OutputFormat.streamJson).should.equal("stream-json");
	(cast(string) SelectEvent.toolResult).should.equal("tool_result");
	(cast(string) ConcurrencyPolicy.replace).should.equal("Replace");
}
