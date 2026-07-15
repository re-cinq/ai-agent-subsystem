module notify;

import core.thread : Thread;
import core.time : msecs;
import std.process : pipeProcess, wait, Redirect;

import agentcore.output.event : EventSource;
import agentcore.core.log : logError;
import agentcore.crds.output_sink : OutputSink;
import agentcore.output.output : emitEvent, headerLines;
import agentcore.output.retry : retryPolicyFromEnv, withRetry;

/// The fixed curl argv: every option (url, method, headers, payload) is fed on stdin
/// via `--config -`, so no secret (a `headers_secret` auth header) ever lands in the
/// argv, which is world-readable through `/proc/<pid>/cmdline`.
static immutable string[] curlArgv = ["curl", "--config", "-"];

/// Emit `payload` as an init event through the shared path (stdout pod logs plus every
/// configured http/file sink), using `curl` for http sinks. A failing sink is retried
/// (bounded backoff) then logged, never fatal (the supervisor emits identically with
/// vibe's client).
void notify(const OutputSink[] sinks, in EventSource src, string payload) nothrow
{
	emitEvent(sinks, src, payload, &postHttp, "[init]");
}

/// POST `line` to an http sink with `curl` and the resolved auth `headers`, retrying
/// transient failures with bounded backoff before giving up. stdout (pod logs) remains
/// the source of truth, so a dropped sink event is logged, never fatal.
private void postHttp(string url, string line, string headers) nothrow
{
	const delivered = withRetry(retryPolicyFromEnv(),
		() => curlOnce(url, line, headers),
		ms => Thread.sleep(ms.msecs));
	if (!delivered)
		logError("[init] http sink failed after retries: " ~ url);
}

/// One POST attempt with the `curl` CLI — already a guaranteed prerequisite, so no HTTP
/// library or event loop is needed. curl reads its whole invocation from a config file on
/// stdin (`--config -`) so the auth headers never appear in argv. `fail`/`show-error`
/// make curl exit non-zero on an HTTP error, so the exit status alone tells us whether to
/// retry; the response body is drained (not inherited) so it never leaks into pod logs.
private bool curlOnce(string url, string line, string headers) nothrow
{
	try
	{
		auto pipes = pipeProcess(curlArgv,
			Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout);
		pipes.stdin.write(curlConfig(url, line, headers));
		pipes.stdin.close();
		foreach (chunk; pipes.stdout.byChunk(4096))
		{
		}
		return wait(pipes.pid) == 0;
	}
	catch (Exception)
		return false;
}

/// Build the curl config (`--config` format) that carries the request: url, POST method,
/// the JSON content-type, the resolved auth headers, and the payload. Fed on stdin so none
/// of it — in particular the auth headers — reaches the argv. Values are quoted and
/// backslash/quote-escaped per curl's config syntax.
string curlConfig(string url, string line, string headers) @safe
{
	string conf = "fail\nsilent\nshow-error\nrequest = \"POST\"\n";
	conf ~= "url = \"" ~ curlConfEscape(url) ~ "\"\n";
	conf ~= "header = \"Content-Type: application/json\"\n";
	foreach (header; headerLines(headers))
		conf ~= "header = \"" ~ curlConfEscape(header) ~ "\"\n";
	conf ~= "data-raw = \"" ~ curlConfEscape(line) ~ "\"\n";
	return conf;
}

/// Escape a value for a curl config double-quoted string: backslash and double-quote
/// are the only metacharacters (header/payload lines never contain a newline).
private string curlConfEscape(string value) @safe
{
	string out_;
	foreach (char c; value)
	{
		if (c == '\\' || c == '"')
			out_ ~= '\\';
		out_ ~= c;
	}
	return out_;
}

version (unittest) import fluent.asserts;
version (unittest) import std.algorithm.searching : canFind;

@safe unittest
{
	// #101: the auth headers go into the curl config (fed on stdin), never the argv, which
	// is world-readable via /proc/<pid>/cmdline. The argv is a fixed secret-free constant.
	curlArgv.should.equal(["curl", "--config", "-"]);

	const conf = curlConfig("https://collector/notify", `{"phase":"init"}`,
		"Authorization: Bearer secret-tok\nX-Env: prod");
	conf.canFind(`header = "Authorization: Bearer secret-tok"`).should.equal(true);
	conf.canFind(`header = "X-Env: prod"`).should.equal(true);
	conf.canFind(`url = "https://collector/notify"`).should.equal(true);
	conf.canFind(`data-raw = "{\"phase\":\"init\"}"`).should.equal(true);
}
