module agentcore.output.httpsink;

import agentcore.batch.provider : HttpRequest, HttpResponse, HttpTransport;
import agentcore.output.output : HttpSink;
import agentcore.core.log : logError;
import agentcore.output.output : headerLines;
import agentcore.output.retry : RetryPolicy, withRetry;
import std.string : indexOf, strip;

/// An `HttpSink` POSTing each line over `transport` with its resolved header block, retrying a
/// connection error or a non-2xx with `policy`'s backoff (slept through `nap`) before logging
/// it with `tag` and giving up: a dropped sink event never fails the run.
HttpSink retryingPoster(HttpTransport transport, RetryPolicy policy, void delegate(int ms) nothrow nap,
	string tag) nothrow
{
	return (string url, string line, string headers) nothrow {
		auto request = HttpRequest("POST", url, headerMap(headers), line);
		if (!withRetry(policy, () => postOnce(transport, request, tag), nap))
			logError(tag ~ " http sink failed after retries: " ~ url);
	};
}

private bool postOnce(HttpTransport transport, HttpRequest request, string tag) nothrow
{
	try
	{
		const status = transport(request).status;
		return status >= 200 && status < 300;
	}
	catch (Exception e)
	{
		logError(tag ~ " http sink attempt failed: " ~ e.msg);
		return false;
	}
}

/// A header block's `Name: value` lines as request headers, with the JSON content type.
private string[string] headerMap(string headers) nothrow
{
	string[string] map = ["content-type": "application/json"];
	foreach (line; headerLines(headers))
	{
		const colon = line.indexOf(':');
		if (colon > 0)
			map[line[0 .. colon].strip] = line[colon + 1 .. $].strip;
	}
	return map;
}

version (unittest) import fluent.asserts;

unittest // poster answered 503 then 200 POSTs the line twice with its split header block
{
	HttpRequest[] requests;
	auto statuses = [503, 200];
	HttpResponse answer(HttpRequest request)
	{
		requests ~= request;
		const status = statuses[0];
		statuses = statuses[1 .. $];
		return HttpResponse(status, "");
	}

	auto post = retryingPoster(&answer, RetryPolicy(3, 0, 0), (int ms) nothrow {}, "[test]");
	post("http://floor/events", `{"i":1}`, "Authorization: Bearer t\nX-Env: prod");

	const expected = HttpRequest("POST", "http://floor/events", ["Authorization": "Bearer t", "X-Env": "prod",
		"content-type": "application/json"], `{"i":1}`);
	(requests == [expected, expected]).should.equal(true);
}
