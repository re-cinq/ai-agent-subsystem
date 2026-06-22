module notify;

import std.process : execute;
import std.stdio : stdout;

import agentcore.event : EventSource, wrapEvent;
import agentcore.log : logError;
import agentcore.output : SinkSpec, deliverSinks;

/// Wrap `payload` in the run's event envelope and fan it out: always to stdout
/// (pod logs → status.output), plus every configured http/file sink. Fire-and-
/// forget — a failing sink is logged, never fatal (mirrors the supervisor's sink
/// semantics).
void notify(const SinkSpec[] sinks, in EventSource src, string payload) nothrow
{
	const line = wrapEvent(src, payload);
	try
	{
		stdout.writeln(line);
		stdout.flush();
	}
	catch (Exception)
	{
	}

	deliverSinks(sinks, line, &postHttp, "[init]");
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
