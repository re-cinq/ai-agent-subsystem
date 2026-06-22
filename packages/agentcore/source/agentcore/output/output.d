module agentcore.output.output;

import std.json : parseJSON;
import std.process : environment;
import std.stdio : File, stdout;

import agentcore.crds.enums : SinkType;
import agentcore.core.env : envNotifyUrl, envSinks;
import agentcore.output.event : EventSource, wrapEvent;
import agentcore.core.log : logError;

/// A resolved output sink: where the supervisor sends each emitted line. The
/// controller builds these from the recipe's `output.sinks` and injects them as
/// JSON (see `parseSinks`).
struct SinkSpec
{
	SinkType type;
	string url; /// for `http`
	string path; /// for `file`
}

/// Parse a JSON array of sinks (the value of the `AGENT_SINKS` env var) into
/// `SinkSpec`s. A malformed document yields an empty list rather than throwing.
SinkSpec[] parseSinks(string json)
{
	if (json.length == 0)
		return null;

	SinkSpec[] sinks;
	try
	{
		foreach (entry; parseJSON(json).array)
		{
			auto obj = entry.object;
			auto type = "type" in obj;
			if (type is null)
				continue;
			SinkSpec s;
			s.type = toSinkType((*type).str);
			if (auto url = "url" in obj)
				s.url = (*url).str;
			if (auto path = "path" in obj)
				s.path = (*path).str;
			sinks ~= s;
		}
	}
	catch (Exception)
		return null;
	return sinks;
}

/// The run's configured sinks, read from the env the controller injects: the
/// recipe's `AGENT_SINKS`, plus a single http sink from the `LORE_NOTIFY_URL`
/// shorthand when set. Shared by the supervisor and the initializer so init and
/// agent output land on the same channel.
SinkSpec[] sinksFromEnv()
{
	auto sinks = parseSinks(environment.get(envSinks, ""));
	const url = environment.get(envNotifyUrl, "");
	if (url.length)
		sinks ~= SinkSpec(SinkType.http, url);
	return sinks;
}

/// How an http sink is delivered — supplied by the caller because it varies by
/// package: the initializer shells out to `curl` (no event loop), the supervisor
/// uses vibe's HTTP client. Must not throw.
alias HttpSink = void function(string url, string line) nothrow;

/// Dispatch `line` to every configured sink: http via the caller's `postHttp`, file
/// by appending, stdout a no-op (callers already echo to their own stdout). Fire-
/// and-forget — a failing file sink is logged with `tag` and never disrupts the run.
void deliverSinks(const SinkSpec[] sinks, string line, HttpSink postHttp, string tag) nothrow
{
	foreach (s; sinks)
	{
		final switch (s.type)
		{
		case SinkType.http:
			postHttp(s.url, line);
			break;
		case SinkType.file:
			appendFile(s.path, line, tag);
			break;
		case SinkType.stdout:
			break;
		}
	}
}

/// Emit one event: wrap `payload` in the run's envelope, echo it to stdout (pod logs),
/// then fan it out to every configured sink. The single path the initializer and the
/// supervisor both emit through — parameterised by the package's http poster, which
/// varies (the initializer shells out to `curl`, the supervisor uses vibe). Fire-and-
/// forget; never throws.
void emitEvent(const SinkSpec[] sinks, in EventSource src, string payload,
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

private SinkType toSinkType(string s)
{
	switch (s)
	{
	case "http":
		return SinkType.http;
	case "file":
		return SinkType.file;
	default:
		return SinkType.stdout;
	}
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
	environment["LORE_NOTIFY_URL"] = "http://collector/n";
	scope (exit)
	{
		environment.remove("AGENT_SINKS");
		environment.remove("LORE_NOTIFY_URL");
	}
	// the LORE_NOTIFY_URL shorthand is appended as an http sink after AGENT_SINKS
	auto sinks = sinksFromEnv();
	sinks.length.should.equal(2);
	sinks[0].type.should.equal(SinkType.file);
	sinks[1].type.should.equal(SinkType.http);
	sinks[1].url.should.equal("http://collector/n");
}

version (unittest) private __gshared string g_posted;

version (unittest) private void recordPost(string url, string line) nothrow
{
	g_posted = url ~ " " ~ line;
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
	SinkSpec[] sinks = [
		SinkSpec(SinkType.http, "http://x", ""),
		SinkSpec(SinkType.file, "", path),
		SinkSpec(SinkType.stdout, "", ""),
	];
	deliverSinks(sinks, "hello", &recordPost, "[test]");

	g_posted.should.equal("http://x hello");
	readText(path).should.equal("hello\n");
}
