module app;

// A configurable stand-in for a real agent CLI, used by the supervisor
// integration tests. Behaviour is driven by environment variables:
//
//   MOCK_LINES  number of `{"i":N}` lines to emit on stdout (default 0)
//   MOCK_EXIT   process exit code (default 0)
//   MOCK_MODE   "emit" (default) | "signal" | "crash" | "orphan"
//                 signal: emit `{"started":1}`, wait for SIGTERM/SIGINT, then
//                         emit `{"signal":N}` and exit MOCK_EXIT
//                 crash:  emit `{"started":1}`, then die from SIGKILL
//                 orphan: spawn a child that inherits stdout and outlives us

import std.conv : to;
import std.process : Config, environment, spawnProcess;
import std.stdio : stderr, stdin, stdout;

import core.stdc.signal : signal;
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
	default:
		break;
	}

	return code;
}
