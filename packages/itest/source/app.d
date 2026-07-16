module app;

// Supervisor integration tests. Spawns the real `ai-agent-supervisor` binary
// against the `ai-agent-mock` binary and asserts on its observable behaviour:
//   - streaming + exit-code passthrough
//   - stdout carries the BARE event lines (pod logs / status.output are the
//     station contract's own stream); source-id attribution rides only on
//     sink deliveries
//   - file + http sinks receive the (enriched) events
//   - all handled signals: SIGTERM + SIGINT forwarded, SIGPIPE ignored
//   - an agent crash surfaces as a non-zero exit
//   - a dead sink is logged and does not fail the run
//   - robustness against an agent that leaves a child holding stdout open
//
//   usage: ai-agent-itest <supervisor-bin> <mock-bin>

import std.algorithm.searching : any, canFind, count, startsWith;
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
		// Wait for the mock's own readiness marker, not the supervisor's `started`
		// lifecycle event (which precedes the agent) — else we'd signal too early.
		if (line.canFind(`"started":1`))
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

/// The agent's own output lines (each mock event carries an `"i":` counter),
/// excluding the supervisor's lifecycle events that now bracket the stream.
private size_t payloadCount(string[] lines)
{
	return lines.count!(l => l.canFind(`"i":`));
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
	lifecycleEvents();
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
	terminalShutdown();
	badArgv();

	writeln(failures == 0 ? "ALL PASSED" : failures.to!string ~ " CHECK(S) FAILED");
	return failures == 0 ? 0 : 1;
}

private void streaming()
{
	writeln("streaming + exit code");
	auto r = run(["MOCK_LINES": "3", "MOCK_EXIT": "0"]);
	check("three events streamed", payloadCount(r.lines) == 3);
	check("payloads intact", emitted(r.lines, `"i":0`) && emitted(r.lines, `"i":2`));
	check("exit 0", r.code == 0);
}

/// The supervisor's lifecycle events mirror the init container's: a typed,
/// `kind`-tagged `agent`-phase stream a developer can hook the same way.
private void lifecycleEvents()
{
	writeln("supervisor raises agent lifecycle events");
	auto r = run(["MOCK_LINES": "1", "MOCK_EXIT": "0"]);
	check("lifecycle events tagged kind + agent phase",
		emitted(r.lines, `"kind":"lifecycle"`) && emitted(r.lines, `"phase":"agent"`));
	check("agent started event raised", emitted(r.lines, `"status":"started"`));
	check("agent succeeded event carries exit code",
		emitted(r.lines, `"status":"succeeded"`) && emitted(r.lines, `"exitCode":0`));
}

private void exitPassthrough()
{
	writeln("exit-code passthrough");
	auto r = run(["MOCK_LINES": "1", "MOCK_EXIT": "7"]);
	check("exit 7", r.code == 7);
	check("non-zero exit raises a failed lifecycle event with the code",
		emitted(r.lines, `"status":"failed"`) && emitted(r.lines, `"exitCode":7`));
}

private void eventIds()
{
	writeln("stdout events are bare; source ids ride only on sinks");
	auto r = run(["MOCK_LINES": "1"]);
	check("stdout event not stamped with agent id", !emitted(r.lines, `"agent":"test-agent"`));
	check("stdout event not stamped with pod id", !emitted(r.lines, `"pod":"test-pod"`));
	check("stdout event not wrapped in an envelope", !emitted(r.lines, `"event":`));
	check("payload forwarded bare", emitted(r.lines, `"i":0`));
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
		withSource(["MOCK_LINES": "3", "AGENT_NOTIFY_URL": "http://127.0.0.1:18099/notify"]));

	// 5 posts: the `agent started` lifecycle event, the 3 agent outputs, then the
	// `agent succeeded` lifecycle event — the same stream the init container produces.
	string[] posts;
	foreach (_; 0 .. 5)
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

	check("agent outputs and lifecycle events all notified", posts.length == 5);
	check("notification payloads intact", emitted(posts, `"i":0`) && emitted(posts, `"i":2`));
	check("lifecycle start + succeeded notified",
		emitted(posts, `"status":"started"`) && emitted(posts, `"exitCode":0`));
	check("notification carries agent id", emitted(posts, `"agent":"test-agent"`));
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
	check("crash raised a failed lifecycle event", emitted(r.lines, `"status":"failed"`));
}

private void deadSinkLogs()
{
	writeln("dead sink: failure logged, run unaffected");
	auto r = run(["MOCK_LINES": "1", "AGENT_NOTIFY_URL": "http://127.0.0.1:1/notify"]);
	check("output still streamed", emitted(r.lines, `"i":0`));
	check("dead sink does not fail the run (exit 0)", r.code == 0);
	check("sink failure logged to stderr", r.err.canFind("sink failed"));
}

private void orphanRobustness()
{
	writeln("orphan robustness (must not hang)");
	auto r = run(["MOCK_MODE": "orphan", "MOCK_LINES": "2", "MOCK_EXIT": "0"]);
	check("both events streamed", payloadCount(r.lines) == 2);
	check("exit 0 without hanging", r.code == 0);
}

/// A real agent CLI can emit its terminal result and then never exit. The
/// supervisor must treat the terminal event as the end of the run and force the
/// lingering process down instead of blocking until the Job deadline (issue #58).
private void terminalShutdown()
{
	// The agent ignores SIGTERM (like a real CLI wedged on a lingering worker), so
	// the supervisor must escalate to SIGKILL — and still report the agent's own
	// success, not the signal that killed it.
	writeln("terminal event force-kills a wedged agent (SIGKILL escalation)");
	auto k = run(["MOCK_MODE": "linger", "MOCK_IGNORE_TERM": "1", "MOCK_LINES": "2",
			"AGENT_EXIT_GRACE_MS": "200"]);
	check("agent outputs streamed before the terminal event", payloadCount(k.lines) == 2);
	check("terminal result forwarded", emitted(k.lines, `"is_error":false`));
	check("exit 0 after SIGKILL (not a deadline)", k.code == 0);
	check("agent succeeded lifecycle event raised",
		emitted(k.lines, `"status":"succeeded"`) && emitted(k.lines, `"exitCode":0`));

	// The agent dies on SIGTERM: the supervisor must report the agent's result
	// (exit 0), not the SIGTERM termination code.
	writeln("terminal event shuts a lingering agent down (SIGTERM, success preserved)");
	auto t = run(["MOCK_MODE": "linger", "MOCK_LINES": "1", "AGENT_EXIT_GRACE_MS": "200"]);
	check("exit 0 from the agent's successful result, not the kill signal", t.code == 0);
	check("agent succeeded lifecycle event raised", emitted(t.lines, `"status":"succeeded"`));
}

private void badArgv()
{
	writeln("missing agent binary");
	auto pipes = pipeProcess([supervisor, "--", "/no-such-agent-binary-xyz"],
		Redirect.stdout | Redirect.stderr, withSource(null));
	string[] lines;
	foreach (line; pipes.stdout.byLine)
		lines ~= line.idup;
	string err;
	foreach (line; pipes.stderr.byLine)
		err ~= line.idup ~ "\n";
	check("exit 1", wait(pipes.pid) == 1);
	check("not-found logged to stderr", err.canFind("agent not found"));
	check("not-found raised as a lifecycle event", emitted(lines, `"reason":"not-found"`));
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
