module sink;

import agentcore.event : EventSource;
import agentcore.log : logError;
import agentcore.output : SinkSpec, emitEvent;

import vibe.http.client : requestHTTP, HTTPClientRequest, HTTPClientResponse;
import vibe.http.common : HTTPMethod;

/// Emit one event: wrap `payload` in the run's envelope, echo it to stdout (pod logs),
/// and fan it out to every configured sink with vibe's HTTP client. Fire-and-forget — a
/// failing sink is logged to stderr but never disrupts the run. A `stdout` sink is a
/// no-op here — the supervisor always echoes to its own stdout. Mirrors the init
/// container's `notify`, so both containers' events land identically.
void emit(const SinkSpec[] sinks, in EventSource src, string payload) nothrow
{
	emitEvent(sinks, src, payload, &postHttp, "[supervisor]");
}

/// POST `line` to an http(s) sink with vibe's HTTP client.
private void postHttp(string url, string line) nothrow
{
	try
		requestHTTP(url,
			(scope HTTPClientRequest req) {
				req.method = HTTPMethod.POST;
				req.writeBody(cast(const(ubyte)[]) line, "application/json");
			},
			(scope HTTPClientResponse res) { res.dropBody(); });
	catch (Exception e)
		logError("[supervisor] http sink failed: " ~ e.msg);
}
