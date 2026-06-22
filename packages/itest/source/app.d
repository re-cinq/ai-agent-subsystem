module app;

// Supervisor integration tests. Spawns the real `ai-agent-supervisor` binary
// against the `ai-agent-mock` binary and asserts on its observable behaviour:
// streaming, exit-code passthrough, file + http sinks, signal forwarding, and
// robustness against an agent that leaves a child holding stdout open.
//
//   usage: ai-agent-itest <supervisor-bin> <mock-bin>

import std.algorithm.searching : canFind, count, startsWith;
import std.conv : to;
import std.file : exists, readText, remove, tempDir;
import std.path : buildPath;
import std.process : pipeProcess, Redirect, wait;
import std.socket;
import std.stdio : stderr, writeln;
import std.string : indexOf, splitLines, strip, toLower;

import core.sys.posix.signal : kill, SIGTERM;

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
}

/// Run the supervisor against the mock and collect its stdout + exit code.
private Result run(string[string] env)
{
	auto pipes = pipeProcess([supervisor, "--", mock], Redirect.stdout, env);
	string[] lines;
	foreach (line; pipes.stdout.byLine)
		lines ~= line.idup;
	return Result(wait(pipes.pid), lines);
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
	fileSink();
	httpSink();
	signalForwarding();
	orphanRobustness();
	badArgv();

	writeln(failures == 0 ? "ALL PASSED" : failures.to!string ~ " CHECK(S) FAILED");
	return failures == 0 ? 0 : 1;
}

private void streaming()
{
	writeln("streaming + exit code");
	auto r = run(["MOCK_LINES": "3", "MOCK_EXIT": "0"]);
	check("three lines streamed", r.lines.length == 3);
	check("first line intact", r.lines.length > 0 && r.lines[0] == `{"i":0}`);
	check("exit 0", r.code == 0);
}

private void exitPassthrough()
{
	writeln("exit-code passthrough");
	auto r = run(["MOCK_LINES": "1", "MOCK_EXIT": "7"]);
	check("exit 7", r.code == 7);
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
	check("file sink received line 0", content.canFind(`{"i":0}`));
	check("file sink received line 1", content.canFind(`{"i":1}`));
	if (exists(path))
		remove(path);
}

private void httpSink()
{
	writeln("http sink");
	auto listener = new TcpSocket();
	listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
	listener.bind(new InternetAddress("127.0.0.1", cast(ushort) 18099));
	listener.listen(8);

	auto pipes = pipeProcess([supervisor, "--", mock], Redirect.stdout,
		["MOCK_LINES": "2", "LORE_NOTIFY_URL": "http://127.0.0.1:18099/notify"]);

	string[] posts;
	foreach (_; 0 .. 2)
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

	check("two posts received", posts.length == 2);
	check("post body intact", posts.length > 0 && posts[0] == `{"i":0}`);
	check("exit 0", code == 0);
}

private void signalForwarding()
{
	writeln("signal forwarding");
	auto pipes = pipeProcess([supervisor, "--", mock], Redirect.stdout,
		["MOCK_MODE": "signal", "MOCK_EXIT": "42"]);

	string[] lines;
	foreach (line; pipes.stdout.byLine)
	{
		lines ~= line.idup;
		if (line.canFind("started"))
			break;
	}
	kill(pipes.pid.processID, SIGTERM); // SIGTERM the supervisor (PID 1 in a pod)
	foreach (line; pipes.stdout.byLine)
		lines ~= line.idup;
	const code = wait(pipes.pid);

	check("agent received the forwarded SIGTERM", lines.canFind(`{"sigterm":1}`));
	check("exit code is the agent's (42)", code == 42);
}

private void orphanRobustness()
{
	writeln("orphan robustness (must not hang)");
	auto r = run(["MOCK_MODE": "orphan", "MOCK_LINES": "2", "MOCK_EXIT": "0"]);
	check("two lines streamed", r.lines.length == 2);
	check("exit 0 without hanging", r.code == 0);
}

private void badArgv()
{
	writeln("missing agent binary");
	auto pipes = pipeProcess([supervisor, "--", "/no-such-agent-binary-xyz"], Redirect.stdout);
	foreach (line; pipes.stdout.byLine)
	{
	}
	check("exit 1", wait(pipes.pid) == 1);
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
