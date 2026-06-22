module notify;

import std.process : execute;

import agentcore.output.event : EventSource;
import agentcore.core.log : logError;
import agentcore.output.output : SinkSpec, emitEvent;

/// Emit `payload` as an init event through the shared path (stdout pod logs plus every
/// configured http/file sink), using `curl` for http sinks. Fire-and-forget — a failing
/// sink is logged, never fatal (the supervisor emits identically with vibe's client).
void notify(const SinkSpec[] sinks, in EventSource src, string payload) nothrow
{
	emitEvent(sinks, src, payload, &postHttp, "[init]");
}

/// POST `line` to an http sink with the `curl` CLI — already a guaranteed
/// prerequisite, so no HTTP library or event loop is needed. `execute` captures
/// curl's output instead of leaking the response body into the pod logs.
private void postHttp(string url, string line) nothrow
{
	try
	{
		const r = execute([
			"curl", "-fsS", "-X", "POST",
			"-H", "Content-Type: application/json",
			"-d", line, url
		]);
		if (r.status != 0)
			logError("[init] http sink failed: curl exited " ~ itoa(r.status));
	}
	catch (Exception e)
		logError("[init] http sink failed: " ~ e.msg);
}

private string itoa(int n) nothrow
{
	try
	{
		import std.conv : to;

		return n.to!string;
	}
	catch (Exception)
		return "?";
}
