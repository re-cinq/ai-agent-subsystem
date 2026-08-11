module sink;

import core.time : msecs;

import agentcore.output.event : EventSource;
import agentcore.core.log : logError;
import agentcore.crds.output_sink : OutputSink;
import agentcore.output.output : emitEvent, headerLines;
import agentcore.output.retry : retryPolicyFromEnv, withRetry;

import std.conv : to;
import std.process : environment;
import std.string : indexOf, strip;
import vibe.core.core : sleep;
import vibe.http.client : requestHTTP, HTTPClientRequest, HTTPClientResponse;
import vibe.http.common : HTTPMethod;

/// Emit one event: wrap `payload` in the run's envelope, echo it to stdout (pod logs),
/// and fan it out to every configured sink with vibe's HTTP client. A failing sink is
/// retried (bounded backoff) then logged, but never disrupts the run. A `stdout` sink is
/// a no-op here — the supervisor always echoes to its own stdout. Mirrors the init
/// container's `notify`, so both containers' events land identically.
void emit(const OutputSink[] sinks, in EventSource src, string payload, bool toSinks = true) nothrow
{
	emitEvent(sinks, src, payload, &postHttp, "[supervisor]", toSinks);
}

/// POST `line` to an http(s) sink with the resolved auth `headers`, retrying transient
/// failures with bounded backoff before giving up. stdout (pod logs) remains the source
/// of truth, so a dropped sink event is logged, never fatal.
private void postHttp(string url, string line, string headers) nothrow
{
	const delivered = withRetry(retryPolicyFromEnv(),
		() => postOnce(url, line, headers),
		ms => napMs(ms));
	if (!delivered)
		logError("[supervisor] http sink failed after retries: " ~ url);
}

/// One POST attempt with vibe's HTTP client; true on a 2xx response. A connection
/// error or a non-2xx status is a retryable failure.
private bool postOnce(string url, string line, string headers) nothrow
{
	try
	{
		bool ok;
		requestHTTP(url,
			(scope HTTPClientRequest req) {
				req.method = HTTPMethod.POST;
				foreach (header; headerLines(headers))
				{
					const colon = header.indexOf(':');
					if (colon > 0)
						req.headers[header[0 .. colon].strip] = header[colon + 1 .. $].strip;
				}
				req.writeBody(cast(const(ubyte)[]) line, "application/json");
			},
			(scope HTTPClientResponse res) {
				ok = res.statusCode >= 200 && res.statusCode < 300;
				res.dropBody();
			});
		return ok;
	}
	catch (Exception e)
	{
		logError("[supervisor] http sink attempt failed: " ~ e.msg);
		return false;
	}
}

/// Cooperative sleep between retries: yields the fiber so the rest of the supervisor
/// keeps running while we wait out a sink blip.
private void napMs(int ms) nothrow
{
	try
		sleep(ms.msecs);
	catch (Exception)
	{
	}
}

/// PUT a conversation archive to the run's registry. Separate from the event sinks:
/// this is a multi-megabyte body, not a line, so it never rides the NDJSON stream that
/// feeds pod logs and `status.output` (both of which cap far below a transcript).
///
/// Auth reuses the sinks' resolved header block, so no new secret is introduced.
/// Failure is logged and swallowed — a lost save costs the NEXT run its continuity,
/// never this one its result.
void postConversation(string url, const(ubyte)[] archive) nothrow
{
	try
	{
		requestHTTP(url, (scope HTTPClientRequest req) {
			req.method = HTTPMethod.POST;
			req.headers["Content-Type"] = "application/gzip";
			foreach (line; headerLines(environment.get("AGENT_CONVERSATION_AUTH", "")))
			{
				const i = line.indexOf(":");
				if (i > 0)
					req.headers[line[0 .. i].strip] = line[i + 1 .. $].strip;
			}
			req.writeBody(archive);
		}, (scope HTTPClientResponse res) {
			if (res.statusCode >= 300)
				logError("[conversation] save rejected: " ~ res.statusCode.to!string);
			res.dropBody();
		});
	}
	catch (Exception e)
		logError("[conversation] save failed: " ~ e.msg);
}
