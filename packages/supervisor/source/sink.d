module sink;

import agentcore.log : logError;
import agentcore.output : SinkSpec, deliverSinks;

import vibe.http.client : requestHTTP, HTTPClientRequest, HTTPClientResponse;
import vibe.http.common : HTTPMethod;

/// Deliver `line` to every configured sink. Each delivery is fire-and-forget: a
/// failing sink is reported to stderr but never disrupts the run. A `stdout` sink
/// is a no-op here — the supervisor always echoes to its own stdout (pod logs).
void deliver(const SinkSpec[] sinks, string line) nothrow
{
	deliverSinks(sinks, line, &postHttp, "[supervisor]");
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
