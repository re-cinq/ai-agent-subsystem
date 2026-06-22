module sink;

import std.stdio : File;

import agentcore.crds.enums : SinkType;
import agentcore.log : logError;
import agentcore.output : SinkSpec;

import vibe.http.client : requestHTTP, HTTPClientRequest, HTTPClientResponse;
import vibe.http.common : HTTPMethod;

/// Deliver `line` to every configured sink. Each delivery is fire-and-forget: a
/// failing sink is reported to stderr but never disrupts the run. A `stdout` sink
/// is a no-op here — the supervisor always echoes to its own stdout (pod logs).
void deliver(const SinkSpec[] sinks, string line) nothrow
{
	foreach (s; sinks)
	{
		final switch (s.type)
		{
		case SinkType.http:
			postHttp(s.url, line);
			break;
		case SinkType.file:
			appendFile(s.path, line);
			break;
		case SinkType.stdout:
			break;
		}
	}
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

/// Append `line` (with a trailing newline) to a file sink.
private void appendFile(string path, string line) nothrow
{
	try
	{
		auto file = File(path, "a");
		scope (exit)
			file.close();
		file.writeln(line);
	}
	catch (Exception e)
		logError("[supervisor] file sink failed: " ~ e.msg);
}
