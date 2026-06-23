module notify;

import core.thread : Thread;
import core.time : msecs;
import std.process : execute;

import agentcore.output.event : EventSource;
import agentcore.core.log : logError;
import agentcore.output.output : SinkSpec, emitEvent;
import agentcore.output.retry : retryPolicyFromEnv, withRetry;

/// Emit `payload` as an init event through the shared path (stdout pod logs plus every
/// configured http/file sink), using `curl` for http sinks. A failing sink is retried
/// (bounded backoff) then logged, never fatal (the supervisor emits identically with
/// vibe's client).
void notify(const SinkSpec[] sinks, in EventSource src, string payload) nothrow
{
	emitEvent(sinks, src, payload, &postHttp, "[init]");
}

/// POST `line` to an http sink with `curl`, retrying transient failures with bounded
/// backoff before giving up. stdout (pod logs) remains the source of truth, so a dropped
/// sink event is logged, never fatal.
private void postHttp(string url, string line) nothrow
{
	const delivered = withRetry(retryPolicyFromEnv(),
		() => curlOnce(url, line),
		ms => Thread.sleep(ms.msecs));
	if (!delivered)
		logError("[init] http sink failed after retries: " ~ url);
}

/// One POST attempt with the `curl` CLI — already a guaranteed prerequisite, so no HTTP
/// library or event loop is needed. `-fsS` makes curl exit non-zero on an HTTP error, so
/// the exit status alone tells us whether to retry. `execute` captures curl's output
/// instead of leaking the response body into the pod logs.
private bool curlOnce(string url, string line) nothrow
{
	try
	{
		const r = execute([
			"curl", "-fsS", "-X", "POST",
			"-H", "Content-Type: application/json",
			"-d", line, url
		]);
		return r.status == 0;
	}
	catch (Exception)
		return false;
}
