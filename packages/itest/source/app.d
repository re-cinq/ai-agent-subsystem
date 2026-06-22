module app;

// Supervisor integration tests. Spawns the real `ai-agent-supervisor` binary
// against the `ai-agent-mock` binary and asserts on its observable behaviour:
//   - streaming + exit-code passthrough
//   - every event is stamped with the run's source ids (agent/pod/station)
//   - file + http sinks receive the (enriched) events
//   - all handled signals: SIGTERM + SIGINT forwarded, SIGPIPE ignored
//   - an agent crash surfaces as a non-zero exit
//   - a dead sink is logged and does not fail the run
//   - robustness against an agent that leaves a child holding stdout open
//
//   usage: ai-agent-itest <supervisor-bin> <mock-bin>

import std.algorithm.searching : any, canFind, startsWith;
import std.conv : to;
import std.file : exists, readText, remove, tempDir;
import std.path : buildPath;
import std.process : pipeProcess, Redirect, wait;
import std.socket;
import std.stdio : stderr, writeln;
import std.string : indexOf, splitLines, strip, toLower;

import core.sys.posix.signal : kill, SIGINT, SIGPIPE, SIGTERM;

private int failures = 0;
private string supervisor;
private string mock;

private void check(string name, bool ok)
{
	writeln(ok ? "  PASS  " : "  FAIL  ", name);
	if (!ok)
		failures++;
}

private struct Result
{
	int code;
	string[] lines;
	string err;
}

/// The identity the controller would inject; the supervisor stamps it onto
/// every event. Merged into every run so assertions can find the ids.
private string[string] withSource(string[string] extra)
{
	string[string] env = [
		"AGENT_NAME": "test-agent",
		"STATION_NAME": "test-station",
		"POD_NAME": "test-pod",
		"POD_NAMESPACE": "ai-agents",
	];
	foreach (k, v; extra)
		env[k] = v;
	return env;
}

/// Run the supervisor against the mock; collect its stdout, stderr and exit code.
private Result run(string[string] extra)
{
	auto pipes = pipeProcess([supervisor, "--", mock], Redirect.stdout | Redirect.stderr,
		withSource(extra));
	string[] lines;
	foreach (line; pipes.stdout.byLine)
		lines ~= line.idup;
	string err;
	foreach (line; pipes.stderr.byLine)
		err ~= line.idup ~ "\n";
	return Result(wait(pipes.pid), lines, err);
}

/// Drive a signal-mode agent: wait for it to start, send `signals` to the
/// supervisor (pid 1 in a pod), then collect the rest of its output.
private Result signalRun(int[] signals)
{
	auto pipes = pipeProcess([supervisor, "--", mock], Redirect.stdout,
		withSource(["MOCK_MODE": "signal", "MOCK_EXIT": "42"]));
	string[] lines;
	foreach (line; pipes.stdout.byLine)
	{
		lines ~= line.idup;
		if (line.canFind("started"))
			break;
	}
	foreach (s; signals)
		kill(pipes.pid.processID, s);
	foreach (line; pipes.stdout.byLine)
		lines ~= line.idup;
	return Result(wait(pipes.pid), lines, "");
}

private bool emitted(string[] lines, string needle)
{
	return lines.any!(l => l.canFind(needle));
}

int main(string[] args)
{
	if (args.length < 3)
	{
		stderr.writeln("usage: ai-agent-itest <supervisor-bin> <mock-bin>");
		return 2;
	}
	supervisor = args[1];
	mock = args[2];

	streaming();
	exitPassthrough();
	eventIds();
	fileSink();
	httpSink();
	signalForwarded();
	interruptForwarded();
	sigpipeIgnored();
	agentCrash();
	deadSinkLogs();
	orphanRobustness();
	badArgv();

	writeln(failures == 0 ? "ALL PASSED" : failures.to!string ~ " CHECK(S) FAILED");
	return failures == 0 ? 0 : 1;
}

private void streaming()
{
	writeln("streaming + exit code");
	auto r = run(["MOCK_LINES": "3", "MOCK_EXIT": "0"]);
	check("three events streamed", r.lines.length == 3);
	check("payloads intact", emitted(r.lines, `"i":0`) && emitted(r.lines, `"i":2`));
	check("exit 0", r.code == 0);
}

private void exitPassthrough()
{
	writeln("exit-code passthrough");
	auto r = run(["MOCK_LINES": "1", "MOCK_EXIT": "7"]);
	check("exit 7", r.code == 7);
}

private void eventIds()
{
	writeln("events carry source ids");
	auto r = run(["MOCK_LINES": "1"]);
	const ok = r.lines.length > 0;
	check("event stamped with agent id", ok && r.lines[0].canFind(`"agent":"test-agent"`));
	check("event stamped with pod id", ok && r.lines[0].canFind(`"pod":"test-pod"`));
	check("event stamped with station id", ok && r.lines[0].canFind(`"station":"test-station"`));
	check("original payload nested under event", ok && r.lines[0].canFind(`"i":0`));
}

private void fileSink()
{
	writeln("file sink");
	const path = buildPath(tempDir, "ai-agent-itest-sink.txt");
	if (exists(path))
		remove(path);
	auto r = run(["MOCK_LINES": "2", "AGENT_SINKS": `[{"type":"file","path":"` ~ path ~ `"}]`]);
	check("exit 0", r.code == 0);
	const content = exists(path) ? readText(path) : "";
	check("file sink received both events", content.canFind(`"i":0`) && content.canFind(`"i":1`));
	check("file sink events carry ids", content.canFind(`"agent":"test-agent"`));
	if (exists(path))
		remove(path);
}

private void httpSink()
{
	writeln("http sink notifications");
	auto listener = new TcpSocket();
	listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
	listener.bind(new InternetAddress("127.0.0.1", cast(ushort) 18_099));
	listener.listen(8);

	auto pipes = pipeProcess([supervisor, "--", mock], Redirect.stdout,
		withSource(["MOCK_LINES": "3", "LORE_NOTIFY_URL": "http://127.0.0.1:18099/notify"]));

	string[] posts;
	foreach (_; 0 .. 3)
	{
		auto conn = listener.accept();
		posts ~= readBody(conn);
		conn.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
		conn.close();
	}
	foreach (line; pipes.stdout.byLine)
	{
	}
	const code = wait(pipes.pid);
	listener.close();

	check("three notifications raised", posts.length == 3);
	check("notification payload intact", posts.length > 0 && posts[0].canFind(`"i":0`));
	check("notification carries agent id", posts.length > 0 && posts[0].canFind(`"agent":"test-agent"`));
	check("exit 0", code == 0);
}

private void signalForwarded()
{
	writeln("SIGTERM forwarded to agent");
	auto r = signalRun([SIGTERM]);
	check("agent received SIGTERM (15)", emitted(r.lines, `"signal":15`));
	check("exit is the agent's code (42)", r.code == 42);
}

private void interruptForwarded()
{
	writeln("SIGINT forwarded to agent");
	auto r = signalRun([SIGINT]);
	check("agent received SIGINT (2)", emitted(r.lines, `"signal":2`));
	check("exit is the agent's code (42)", r.code == 42);
}

private void sigpipeIgnored()
{
	writeln("SIGPIPE ignored (does not kill the supervisor)");
	auto r = signalRun([SIGPIPE, SIGTERM]);
	check("survived SIGPIPE and still forwarded SIGTERM", emitted(r.lines, `"signal":15`));
	check("exit is the agent's code (42)", r.code == 42);
}

private void agentCrash()
{
	writeln("agent crash (SIGKILL)");
	auto r = run(["MOCK_MODE": "crash"]);
	check("start event captured before the crash", emitted(r.lines, `"started":1`));
	check("crash surfaced as a non-zero exit", r.code != 0);
}

private void deadSinkLogs()
{
	writeln("dead sink: failure logged, run unaffected");
	auto r = run(["MOCK_LINES": "1", "LORE_NOTIFY_URL": "http://127.0.0.1:1/notify"]);
	check("output still streamed", emitted(r.lines, `"i":0`));
	check("dead sink does not fail the run (exit 0)", r.code == 0);
	check("sink failure logged to stderr", r.err.canFind("sink failed"));
}

private void orphanRobustness()
{
	writeln("orphan robustness (must not hang)");
	auto r = run(["MOCK_MODE": "orphan", "MOCK_LINES": "2", "MOCK_EXIT": "0"]);
	check("both events streamed", r.lines.length == 2);
	check("exit 0 without hanging", r.code == 0);
}

private void badArgv()
{
	writeln("missing agent binary");
	auto pipes = pipeProcess([supervisor, "--", "/no-such-agent-binary-xyz"],
		Redirect.stdout | Redirect.stderr, withSource(null));
	foreach (line; pipes.stdout.byLine)
	{
	}
	string err;
	foreach (line; pipes.stderr.byLine)
		err ~= line.idup ~ "\n";
	check("exit 1", wait(pipes.pid) == 1);
	check("not-found logged to stderr", err.canFind("agent not found"));
}

/// Read one HTTP request from `conn` and return its body (Content-Length bytes).
private string readBody(Socket conn)
{
	char[4096] buf;
	string data;
	while (true)
	{
		const n = conn.receive(buf[]);
		if (n <= 0)
			break;
		data ~= buf[0 .. cast(size_t) n].idup;
		const headerEnd = data.indexOf("\r\n\r\n");
		if (headerEnd != -1)
		{
			const length = contentLength(data[0 .. headerEnd]);
			const bodyStart = headerEnd + 4;
			if (data.length - bodyStart >= length)
				return data[bodyStart .. bodyStart + length];
		}
	}
	return "";
}

private size_t contentLength(string headers)
{
	foreach (line; headers.splitLines)
		if (line.toLower.startsWith("content-length:"))
			return line[15 .. $].strip.to!size_t;
	return 0;
}
