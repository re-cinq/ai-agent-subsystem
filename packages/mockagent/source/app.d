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

int main()
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
	default:
		break;
	}

	return code;
}
