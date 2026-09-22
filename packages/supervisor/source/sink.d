module sink;

import core.time : msecs;

import agentcore.output.event : EventSource;
import agentcore.core.log : logError;
import agentcore.crds.output_sink : OutputSink;
import agentcore.core.env : envConversationAuth;
import agentcore.output.output : emitEvent, headerLines, sinkHeaders;
import agentcore.output.retry : RetryPolicy, retryPolicyFromEnv, withRetry;

import std.conv : to;
import std.process : environment;
import std.string : indexOf, strip;
import vibe.core.core : sleep;
import vibe.http.client : requestHTTP, HTTPClientRequest, HTTPClientResponse;
import vibe.http.common : HTTPMethod;

version (unittest) import fluent.asserts;

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
				setHeaders(req, headers);
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

/// Set each `Name: value` line of a resolved header block on `req`.
private void setHeaders(scope HTTPClientRequest req, string headers)
{
	foreach (line; headerLines(headers))
	{
		const colon = line.indexOf(':');
		if (colon > 0)
			req.headers[line[0 .. colon].strip] = line[colon + 1 .. $].strip;
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
			// AGENT_CONVERSATION_AUTH holds the NAME of the injected secret key, so
			// resolve it the same way sinkHeaders does rather than treating it as the
			// credential itself.
			setHeaders(req, sinkHeaders(environment.get(envConversationAuth, "")));
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

/// What one upload attempt came to: delivered, refused for good, or worth another try.
enum UploadAttempt
{
	delivered,
	refused,
	retry,
}

/// A 2xx delivered the file; any other 4xx will be refused again, since the same bytes
/// get the same answer; a timeout, a throttle or a 5xx is the receiver, not the file.
UploadAttempt uploadAttemptFor(int status) @safe pure nothrow
{
	if (status >= 200 && status < 300)
		return UploadAttempt.delivered;
	const transient = status == 408 || status == 429 || status >= 500;
	return transient ? UploadAttempt.retry : UploadAttempt.refused;
}

unittest
{
	uploadAttemptFor(200).should.equal(UploadAttempt.delivered);
	uploadAttemptFor(404).should.equal(UploadAttempt.refused);
	uploadAttemptFor(400).should.equal(UploadAttempt.refused);
	uploadAttemptFor(429).should.equal(UploadAttempt.retry);
	uploadAttemptFor(503).should.equal(UploadAttempt.retry);
}

/// Longer than a sink's: the receiver may be mid-rollout, when a connection can reach a
/// replica that is shutting down for a few seconds, and a lost upload costs the run
/// its artifact rather than one line of telemetry.
private enum uploadRetry = RetryPolicy(5, 1000, 8000);

/// POST one watched file's bytes to its upload url, with the header block its
/// `headers_secret` names resolved the way a sink's is. True on a 2xx. A connection
/// error or a transient status is retried with backoff; a refusal is not. A failure is
/// logged by status only — never the body, which is the agent's artifact, nor the
/// headers, which carry the credential — and the file event reports it.
bool postUpload(string url, const(ubyte)[] body_, string headersSecret) nothrow
{
	auto last = UploadAttempt.retry;
	withRetry(uploadRetry, () {
		last = uploadOnce(url, body_, headersSecret);
		return last != UploadAttempt.retry;
	}, ms => napMs(ms));
	return last == UploadAttempt.delivered;
}

private UploadAttempt uploadOnce(string url, const(ubyte)[] body_, string headersSecret) nothrow
{
	try
	{
		auto attempt = UploadAttempt.retry;
		requestHTTP(url, (scope HTTPClientRequest req) {
			req.method = HTTPMethod.POST;
			setHeaders(req, sinkHeaders(headersSecret));
			req.writeBody(body_, "application/octet-stream");
		}, (scope HTTPClientResponse res) {
			attempt = uploadAttemptFor(res.statusCode);
			if (attempt != UploadAttempt.delivered)
				logError("[watch] upload rejected: " ~ res.statusCode.to!string);
			res.dropBody();
		});
		return attempt;
	}
	catch (Exception e)
	{
		logError("[watch] upload failed: " ~ e.msg);
		return UploadAttempt.retry;
	}
}
