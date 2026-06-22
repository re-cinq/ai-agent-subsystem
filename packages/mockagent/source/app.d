module app;

// A configurable stand-in for a real agent CLI, used by the supervisor
// integration tests. Behaviour is driven by environment variables:
//
//   MOCK_LINES  number of `{"i":N}` lines to emit on stdout (default 0)
//   MOCK_EXIT   process exit code (default 0)
//   MOCK_MODE   "emit" (default) | "signal" | "orphan"
//                 signal: emit `{"started":1}`, wait for SIGTERM, then emit
//                         `{"sigterm":1}` and exit MOCK_EXIT
//                 orphan: spawn a child that inherits stdout and outlives us
//                         (to exercise the supervisor's process-exit handling)

import std.conv : to;
import std.process : Config, environment, spawnProcess;
import std.stdio : stderr, stdin, stdout;

import core.stdc.signal : signal, SIGTERM;
import core.thread : Thread;
import core.time : msecs;

private __gshared bool g_terminated = false;

extern (C) private void onTerm(int) nothrow @nogc @system
{
	g_terminated = true;
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
		signal(SIGTERM, &onTerm);
		emit(`{"started":1}`);
		while (!g_terminated)
			Thread.sleep(20.msecs);
		emit(`{"sigterm":1}`);
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
