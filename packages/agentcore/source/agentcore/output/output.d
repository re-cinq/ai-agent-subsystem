module agentcore.output.output;

import vibe.data.json : Json, parseJsonString;
import std.process : environment;
import std.stdio : File, stdout;

import agentcore.crds.enums : SinkType;
import agentcore.crds.output_sink : OutputSink;
import agentcore.crds.serialization : fromJson;
import agentcore.core.env : envNotifyUrl, envSinks;
import agentcore.output.event : EventSource, wrapEvent;
import agentcore.core.log : logError;

/// Parse a JSON array of sinks (the value of the `AGENT_SINKS` env var) into the
/// `OutputSink` CRD structs the controller serialized — the same type, so no field
/// can be silently dropped at this seam. An entry missing its `type` is skipped (the
/// controller never emits one); a malformed document yields an empty list rather
/// than throwing.
OutputSink[] parseSinks(string json)
{
	if (json.length == 0)
		return null;

	OutputSink[] sinks;
	try
	{
		foreach (entry; parseJsonString(json).get!(Json[]))
			if ("type" in entry)
				sinks ~= fromJson!OutputSink(entry);
	}
	catch (Exception)
		return null;
	return sinks;
}

/// The run's configured sinks, read from the env the controller injects: the
/// recipe's `AGENT_SINKS`, plus a single http sink from the `AGENT_NOTIFY_URL`
/// shorthand when set. Shared by the supervisor and the initializer so init and
/// agent output land on the same channel.
OutputSink[] sinksFromEnv()
{
	auto sinks = parseSinks(environment.get(envSinks, ""));
	const url = environment.get(envNotifyUrl, "");
	if (url.length)
		sinks ~= OutputSink(SinkType.http, url);
	return sinks;
}

/// How an http sink is delivered — supplied by the caller because it varies by
/// package: the initializer shells out to `curl` (no event loop), the supervisor
/// uses vibe's HTTP client. `headers` is the resolved auth-header block (newline-
/// separated `Name: value` lines, empty when the sink has no `headers_secret`).
/// Must not throw.
alias HttpSink = void function(string url, string line, string headers) nothrow;

/// Dispatch `line` to every configured sink: http via the caller's `postHttp` (with
/// the sink's resolved auth headers), file by appending, stdout a no-op (callers
/// already echo to their own stdout). Fire-and-forget — a failing file sink is
/// logged with `tag` and never disrupts the run.
void deliverSinks(const OutputSink[] sinks, string line, HttpSink postHttp, string tag) nothrow
{
	foreach (s; sinks)
	{
		final switch (s.type)
		{
		case SinkType.http:
			postHttp(s.url, line, sinkHeaders(s.headersSecret));
			break;
		case SinkType.file:
			appendFile(s.path, line, tag);
			break;
		case SinkType.stdout:
			break;
		}
	}
}

/// Resolve a sink's `headers_secret` to its header block: the controller injects the
/// referenced Secret key as an env var of the same name, so this reads it back. Empty
/// (no headers) when unset or unresolvable — auth is never allowed to break the run.
string sinkHeaders(string headersSecret) nothrow
{
	if (headersSecret.length == 0)
		return "";
	try
		return environment.get(headersSecret, "");
	catch (Exception)
		return "";
}

/// Split a resolved header block into its individual `Name: value` lines, dropping
/// blank ones. Shared by both http posters — the supervisor splits each line into a
/// vibe request header, the initializer passes each straight to `curl -H`.
string[] headerLines(string headers) @safe nothrow
{
	import std.string : splitLines, strip;

	string[] lines;
	try
		foreach (line; headers.splitLines)
		{
			const trimmed = line.strip;
			if (trimmed.length)
				lines ~= trimmed;
		}
	catch (Exception)
	{
	}
	return lines;
}

/// Emit one event: wrap `payload` in the run's envelope, echo it to stdout (pod logs),
/// then fan it out to every configured sink. The single path the initializer and the
/// supervisor both emit through — parameterised by the package's http poster, which
/// varies (the initializer shells out to `curl`, the supervisor uses vibe). Fire-and-
/// forget; never throws.
void emitEvent(const OutputSink[] sinks, in EventSource src, string payload,
	HttpSink postHttp, string tag, bool toSinks = true) nothrow
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
	// stdout (pod logs / status.output) always gets every event; sink delivery is
	// gated by the recipe's output.select (the caller passes the verdict).
	if (toSinks)
		deliverSinks(sinks, line, postHttp, tag);
}

/// Append `line` (with a trailing newline) to a file sink.
private void appendFile(string path, string line, string tag) nothrow
{
	try
	{
		auto file = File(path, "a");
		scope (exit)
			file.close();
		file.writeln(line);
	}
	catch (Exception e)
		logError(tag ~ " file sink failed: " ~ e.msg);
}

version (unittest) import fluent.asserts;

unittest
{
	auto sinks = parseSinks(`[{"type":"http","url":"http://collector/x"},{"type":"file","path":"/tmp/out"}]`);
	sinks.length.should.equal(2);
	sinks[0].type.should.equal(SinkType.http);
	sinks[0].url.should.equal("http://collector/x");
	sinks[1].type.should.equal(SinkType.file);
	sinks[1].path.should.equal("/tmp/out");

	parseSinks("").should.beNull;
	parseSinks("not json").should.beNull;
	parseSinks("[]").length.should.equal(0);
	// entries without a type are skipped
	parseSinks(`[{"url":"http://x"}]`).length.should.equal(0);
}

unittest
{
	environment["AGENT_SINKS"] = `[{"type":"file","path":"/tmp/out"}]`;
	environment["AGENT_NOTIFY_URL"] = "http://collector/n";
	scope (exit)
	{
		environment.remove("AGENT_SINKS");
		environment.remove("AGENT_NOTIFY_URL");
	}
	// the AGENT_NOTIFY_URL shorthand is appended as an http sink after AGENT_SINKS
	auto sinks = sinksFromEnv();
	sinks.length.should.equal(2);
	sinks[0].type.should.equal(SinkType.file);
	sinks[1].type.should.equal(SinkType.http);
	sinks[1].url.should.equal("http://collector/n");
}

version (unittest) private __gshared string g_posted;
version (unittest) private __gshared string g_postedHeaders;

version (unittest) private void recordPost(string url, string line, string headers) nothrow
{
	g_posted = url ~ " " ~ line;
	g_postedHeaders = headers;
}

unittest
{
	import std.file : readText, exists, remove, tempDir;
	import std.path : buildPath;

	const path = buildPath(tempDir, "agentcore-sink-test.log");
	if (exists(path))
		remove(path);
	scope (exit)
		if (exists(path))
			remove(path);

	g_posted = "";
	OutputSink[] sinks = [
		OutputSink(SinkType.http, "http://x"),
		OutputSink(SinkType.file, "", "", path),
		OutputSink(SinkType.stdout),
	];
	deliverSinks(sinks, "hello", &recordPost, "[test]");

	g_posted.should.equal("http://x hello");
	readText(path).should.equal("hello\n");
}

unittest
{
	// An http sink's headers_secret names an env var (the controller injects the
	// referenced Secret key under that name); deliverSinks resolves it and hands the
	// header block to the poster. An unset secret resolves to no headers.
	environment["SINK_HEADERS"] = "Authorization: Bearer tok\nX-Env: prod";
	scope (exit)
		environment.remove("SINK_HEADERS");

	g_posted = "";
	g_postedHeaders = "";
	deliverSinks([OutputSink(SinkType.http, "http://x", "SINK_HEADERS")], "hi", &recordPost, "[test]");
	g_postedHeaders.should.equal("Authorization: Bearer tok\nX-Env: prod");

	g_postedHeaders = "sentinel";
	deliverSinks([OutputSink(SinkType.http, "http://x")], "hi", &recordPost, "[test]");
	g_postedHeaders.should.equal("");
}
