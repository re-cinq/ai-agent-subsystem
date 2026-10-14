module batchhttp;

import core.time : seconds;

import vibe.http.client : HTTPClientRequest, HTTPClientResponse, HTTPClientSettings, requestHTTP;
import vibe.http.common : httpMethodFromString;
import vibe.stream.operations : readAllUTF8;

import agentcore.batch.provider : HttpRequest, HttpResponse;
import agentcore.output.httpsink : retryingPoster;
import agentcore.output.output : HttpSink;
import agentcore.output.retry : retryPolicyFromEnv;

/// The poster a batch run's events reach its http sinks through: `batchTransport` with the
/// supervisor's retry policy, yielding the fiber between attempts.
HttpSink sinkPoster() nothrow
{
	return retryingPoster((request) => batchTransport(request), retryPolicyFromEnv(), (int ms) nothrow {
		import core.time : msecs;
		import vibe.core.core : sleep;

		try
			sleep(ms.msecs);
		catch (Exception)
		{
		}
	}, "[controller]");
}

/// The `HttpTransport` batch providers and the model catalog reach vendor APIs through: one HTTPS request
/// with connect and read timeouts, trusting the system CA store.
HttpResponse batchTransport(HttpRequest request)
{
	auto settings = new HTTPClientSettings;
	settings.connectTimeout = 10.seconds;
	settings.readTimeout = 60.seconds;

	HttpResponse response;
	requestHTTP(request.url,
		(scope HTTPClientRequest req) {
			req.method = httpMethodFromString(request.method);
			foreach (name, value; request.headers)
				req.headers[name] = value;
			if (request.body.length)
				req.writeBody(cast(const(ubyte)[]) request.body, request.headers.get("content-type", ""));
		},
		(scope HTTPClientResponse res) {
			response.status = res.statusCode;
			response.body = res.bodyReader.readAllUTF8;
		}, settings);
	return response;
}
