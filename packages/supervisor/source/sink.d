module sink;

import agentcore.log : logError;

import vibe.http.client : requestHTTP, HTTPClientRequest, HTTPClientResponse;
import vibe.http.common : HTTPMethod;

/// POST `line` (a JSON event) to `url` with vibe's HTTP client. A failed post is
/// reported — its message only, not a stack trace — to stderr, but never disrupts
/// the run: a missing or slow sink must not interrupt the agent's output stream.
void postLine(string url, string line) nothrow
{
	try
		requestHTTP(url,
			(scope HTTPClientRequest req) {
				req.method = HTTPMethod.POST;
				req.writeBody(cast(const(ubyte)[]) line, "application/json");
			},
			(scope HTTPClientResponse res) { res.dropBody(); });
	catch (Exception e)
		logError("[supervisor] sink post failed: " ~ e.msg);
}
