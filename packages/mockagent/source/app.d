module app;

// A configurable stand-in for a real agent CLI, used by the supervisor
// integration tests. Behaviour is driven by environment variables:
//
//   MOCK_LINES  number of `{"i":N}` lines to emit on stdout (default 0)
//   MOCK_EXIT   process exit code (default 0)
//   MOCK_STDERR a line written to stderr before the mode runs (default none) — stands
//               in for the auth errors and stack traces a real CLI prints there
//   MOCK_WRITE_FILE path of a file to create before exiting — stands in for an agent
//               whose deliverable is an artifact rather than its stdout
//   MOCK_WRITE_BODY contents to write there (default `{"ok":true}`)
//   MOCK_STDERR_LINES how many times to write it (default 1). Enough of them overflow
//               the stderr pipe buffer, which blocks the supervisor's write unless the
//               reader drains stderr concurrently with stdout
//   MOCK_SESSION a session id announced first, as Claude's `system/init` event does
//   MOCK_MODE   "emit" (default) | "signal" | "crash" | "orphan" | "linger" | "wedge"
//                 signal: emit `{"started":1}`, wait for SIGTERM/SIGINT, then
//                         emit `{"signal":N}` and exit MOCK_EXIT
//                 crash:  emit `{"started":1}`, then die from SIGKILL
//                 orphan: spawn a child that inherits stdout and outlives us
//                 linger: emit a Claude-style terminal `result`, then ignore
//                         SIGTERM and hang forever — like a real agent CLI that
//                         finishes its work but never exits
//                 wedge:  emit no terminal event, ignore SIGTERM and hang forever —
//                         like an agent stuck on a call that never returns
//                 chat:   a Claude-style stdin session: emits `{"token":…}` with the
//                         value of AGENT_REALTIME_TOKEN it inherited, then, for each
//                         stream-json user line on stdin, a `system/init` carrying
//                         MOCK_SESSION and a `result` whose text is `echo:<prompt>`.
//                         Exits MOCK_EXIT at stdin EOF
//                 turn:   one Codex-style turn: `thread.started` carrying MOCK_SESSION,
//                         `{"argv":[…]}` with its own arguments, then `turn.completed`
//                 serve:  not an agent at all — a local HTTP fixture for the init's
//                         file download and the courier's GitHub API. Listens on
//                         127.0.0.1:MOCK_SERVE_PORT, answers every request
//                         MOCK_SERVE_STATUS (default 200) with MOCK_SERVE_BODY, appends
//                         each whole request to MOCK_SERVE_LOG, and runs until killed. Emits
//                         `{"listening":1}` once it accepts connections

import std.conv : to;
import std.process : Config, environment, spawnProcess;
import std.stdio : stderr, stdin, stdout;

import core.stdc.signal : signal, SIG_IGN;
import core.sys.posix.signal : kill, SIGINT, SIGKILL, SIGTERM;
import core.sys.posix.unistd : getpid;
import core.thread : Thread;
import core.time : msecs;

private __gshared int g_signal = 0;

extern (C) private void onSignal(int sig) nothrow @nogc @system
{
	g_signal = sig;
}

void emit(string line)
{
	stdout.writeln(line);
	stdout.flush();
}

int main(string[] args)
{
	const mode = environment.get("MOCK_MODE", "emit");
	const lines = environment.get("MOCK_LINES", "0").to!int;
	const code = environment.get("MOCK_EXIT", "0").to!int;

	const writeFile = environment.get("MOCK_WRITE_FILE", "");
	if (writeFile.length)
	{
		import std.file : mkdirRecurse, write;
		import std.path : dirName;

		mkdirRecurse(writeFile.dirName);
		write(writeFile, environment.get("MOCK_WRITE_BODY", `{"ok":true}`));
	}

	const errLine = environment.get("MOCK_STDERR", "");
	if (errLine.length)
	{
		foreach (i; 0 .. environment.get("MOCK_STDERR_LINES", "1").to!int)
			stderr.writeln(errLine);
		stderr.flush();
	}

	const session = environment.get("MOCK_SESSION", "");
	if (session.length && mode != "chat" && mode != "turn")
		emit(`{"type":"system","subtype":"init","session_id":"` ~ session ~ `"}`);

	foreach (i; 0 .. lines)
		emit(`{"i":` ~ i.to!string ~ `}`);

	switch (mode)
	{
	case "signal":
		signal(SIGINT, &onSignal);
		signal(SIGTERM, &onSignal);
		emit(`{"started":1}`);
		while (g_signal == 0)
			Thread.sleep(20.msecs);
		emit(`{"signal":` ~ g_signal.to!string ~ `}`);
		break;
	case "crash":
		emit(`{"started":1}`);
		kill(getpid(), SIGKILL);
		break;
	case "orphan":
		// inherits our stdout and keeps running after we exit, so the pipe
		// never reaches EOF on its own.
		spawnProcess(["sleep", "30"], stdin, stdout, stderr, null, Config.detached);
		break;
	case "linger":
		if (environment.get("MOCK_IGNORE_TERM", "") == "1")
			signal(SIGTERM, SIG_IGN);
		emit(`{"type":"result","subtype":"success","is_error":false}`);
		while (true)
			Thread.sleep(60.msecs);
	case "wedge":
		// No terminal event and no exit: only a deadline can end this run.
		signal(SIGTERM, SIG_IGN);
		while (true)
			Thread.sleep(60.msecs);
	case "serve":
		serve();
		break;
	case "chat":
		chat(session);
		break;
	case "turn":
		emit(`{"type":"thread.started","thread_id":"` ~ session ~ `"}`);
		emit(`{"argv":` ~ jsonStrings(args[1 .. $]) ~ `}`);
		emit(`{"type":"turn.completed","usage":{"input_tokens":1}}`);
		break;
	default:
		break;
	}

	return code;
}

/// The `chat` mode: answer each stream-json user line on stdin until EOF.
private void chat(string session)
{
	import std.string : indexOf;

	emit(`{"token":"` ~ environment.get("AGENT_REALTIME_TOKEN", "") ~ `"}`);
	foreach (line; stdin.byLine)
	{
		enum marker = `"text":"`;
		const start = line.indexOf(marker);
		const text = start < 0 ? "" : line[start + marker.length .. $].idup;
		const prompt = text[0 .. text.indexOf('"') < 0 ? text.length : text.indexOf('"')];
		emit(`{"type":"system","subtype":"init","session_id":"` ~ session ~ `"}`);
		emit(`{"type":"result","subtype":"success","is_error":false,"result":"echo:` ~ prompt ~ `"}`);
	}
}

/// `values` as a JSON array of strings; the itests pass no quotes or backslashes.
private string jsonStrings(string[] values)
{
	import std.array : join;
	import std.algorithm.iteration : map;

	return "[" ~ values.map!(value => `"` ~ value ~ `"`).join(",") ~ "]";
}

/// The `serve` mode's HTTP fixture: one request per connection, answered in full.
private void serve()
{
	import std.file : append;
	import std.socket : InternetAddress, SocketOption, SocketOptionLevel, TcpSocket;
	import std.string : indexOf;

	const port = environment.get("MOCK_SERVE_PORT", "18200").to!ushort;
	const body_ = environment.get("MOCK_SERVE_BODY", "served");
	const status = environment.get("MOCK_SERVE_STATUS", "200");
	const log = environment.get("MOCK_SERVE_LOG", "");

	auto listener = new TcpSocket();
	listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
	listener.bind(new InternetAddress("127.0.0.1", port));
	listener.listen(8);
	emit(`{"listening":1}`);

	while (true)
	{
		auto conn = listener.accept();
		char[4096] buf;
		string request;
		while (request.indexOf("\r\n\r\n") < 0 || request.length < requestLength(request))
		{
			const n = conn.receive(buf[]);
			if (n <= 0)
				break;
			request ~= buf[0 .. cast(size_t) n].idup;
		}
		if (log.length)
			append(log, request ~ "\n");
		conn.send("HTTP/1.1 " ~ status ~ " Mock\r\nContent-Length: " ~ body_.length.to!string
				~ "\r\nConnection: close\r\n\r\n" ~ body_);
		conn.close();
	}
}

/// The full length of a request whose head is complete: the head plus its
/// `Content-Length` body, so a POST is logged whole.
private size_t requestLength(string request)
{
	import std.string : indexOf, splitLines, strip, toLower;

	const headEnd = request.indexOf("\r\n\r\n") + 4;
	foreach (line; request[0 .. headEnd].splitLines)
		if (line.toLower.indexOf("content-length:") == 0)
			return headEnd + line["content-length:".length .. $].strip.to!size_t;
	return headEnd;
}
