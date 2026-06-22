module supervise;

import std.stdio : stdout;

import core.stdc.signal : signal, SIG_IGN, SIGINT, SIGTERM;
import core.sys.posix.signal : kill, SIGPIPE;
import core.sys.posix.sys.types : pid_t;
import core.time : msecs;

import vibe.core.core : disableDefaultSignalHandlers, runTask, sleep;
import vibe.core.process : pipeProcess, Redirect, ProcessPipes;
import vibe.stream.operations : readLine;

import agentcore.event : sourceFromEnv, wrapEvent;
import agentcore.exec : findExecutable;
import agentcore.log : logError;
import agentcore.output : sinksFromEnv;
import sink : deliver;

/// PID of the spawned agent, shared with the signal handler.
private __gshared pid_t g_childPid = 0;

/// Forward a received termination signal to the agent for graceful shutdown.
extern (C) private void forwardSignal(int sig) nothrow @nogc @system
{
	if (g_childPid > 0)
		kill(g_childPid, sig);
}

/// Take over signal handling from vibe: ignore `SIGPIPE` (so a broken sink socket
/// can't kill us) and forward `SIGTERM`/`SIGINT` to the agent once it is running.
/// Call once, before the event loop starts.
void installSignalForwarding()
{
	disableDefaultSignalHandlers();
	signal(SIGPIPE, SIG_IGN);
	signal(SIGTERM, &forwardSignal);
	signal(SIGINT, &forwardSignal);
}

/// Supervise `agentArgv` (built by the controller from the recipe): spawn it,
/// stream its newline-delimited JSON output to stdout and every configured sink,
/// and return its exit code. Runs inside a vibe task so the sinks' HTTP client
/// shares the event loop. (Auth is the agent's own concern — the controller
/// injects provider API keys as env vars.)
int supervise(string[] agentArgv)
{
	if (findExecutable(agentArgv[0]).length == 0)
	{
		logError("[supervisor] agent not found: " ~ agentArgv[0]);
		return 1;
	}

	const sinks = sinksFromEnv();
	const source = sourceFromEnv();

	ProcessPipes pipes;
	try
		pipes = pipeProcess(agentArgv, Redirect.stdout);
	catch (Exception e)
	{
		logError("[supervisor] failed to start agent: " ~ e.msg);
		return 1;
	}

	g_childPid = pipes.process.pid;

	// Stream stdout in its own task so the agent's *process exit* ends the run,
	// not stdout EOF: a stray child that inherits and holds stdout open would
	// otherwise keep the pipe from ever reaching EOF and hang the loop.
	auto reader = runTask(() nothrow {
		try
		{
			while (!pipes.stdout.empty)
			{
				auto raw = pipes.stdout.readLine(size_t.max, "\n");
				if (raw.length == 0)
					continue;
				const event = wrapEvent(source, cast(string) raw.idup);
				stdout.writeln(event);
				stdout.flush();
				deliver(sinks, event);
			}
		}
		catch (Exception)
		{
			// stdout closed (normal EOF) or the reader was interrupted on exit.
		}
	});

	const code = pipes.process.wait();

	// The reader normally finishes as stdout EOFs right after the agent exits.
	// Give it a brief grace to drain buffered output, then stop it if a stray
	// child is still holding stdout open.
	sleep(100.msecs);
	if (reader.running)
		reader.interrupt();
	reader.join();

	// Release our end of the pipe so eventcore doesn't warn about a still-open
	// handle when a stray child kept the write end open.
	pipes.stdout.close();

	return code;
}
