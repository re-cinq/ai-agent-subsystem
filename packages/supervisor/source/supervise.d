module supervise;

import std.algorithm.searching : canFind;
import std.file : exists, isFile;
import std.path : buildPath;
import std.process : environment;
import std.stdio : stdout;
import std.string : split;

import core.stdc.signal : signal, SIG_IGN, SIGINT, SIGTERM;
import core.sys.posix.signal : kill, SIGPIPE;
import core.sys.posix.sys.types : pid_t;
import core.time : msecs;

import vibe.core.core : disableDefaultSignalHandlers, runTask, sleep;
import vibe.core.process : pipeProcess, Redirect, ProcessPipes;
import vibe.stream.operations : readLine;

import agentcore.crds.enums : SinkType;
import agentcore.env : envAgentName, envNotifyUrl, envPodName, envPodNamespace,
	envSinks, envStationName, envTaskId;
import agentcore.event : EventSource, wrapEvent;
import agentcore.log : logError;
import agentcore.output : SinkSpec, parseSinks;
import sink : deliver;

version (unittest) import fluent.asserts;

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

	const sinks = buildSinks();
	const source = buildSource();

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

/// The sinks to deliver to: the recipe's `AGENT_SINKS`, plus a single http sink
/// from the `LORE_NOTIFY_URL` shorthand when set.
private SinkSpec[] buildSinks()
{
	auto sinks = parseSinks(environment.get(envSinks, ""));
	const notify = environment.get(envNotifyUrl, "");
	if (notify.length)
		sinks ~= SinkSpec(SinkType.http, notify);
	return sinks;
}

/// The run's identity, read from the env the controller injects, stamped onto
/// every event so a workflow can correlate it back to its agent + pod.
private EventSource buildSource()
{
	EventSource s;
	s.agent = environment.get(envAgentName, "");
	s.station = environment.get(envStationName, "");
	s.task = environment.get(envTaskId, "");
	s.pod = environment.get(envPodName, "");
	s.namespace_ = environment.get(envPodNamespace, "");
	return s;
}

/// Resolve `cmd` to an existing file: the path itself when it contains a `/`,
/// else the first match on `PATH`. Returns "" when not found. Used to fail a bad
/// agent argv cleanly instead of leaking the half-spawned process's pipes.
string findExecutable(string cmd)
{
	if (cmd.canFind('/'))
		return (exists(cmd) && isFile(cmd)) ? cmd : "";

	foreach (dir; environment.get("PATH", "").split(':'))
	{
		if (dir.length == 0)
			continue;
		const candidate = buildPath(dir, cmd);
		if (exists(candidate) && isFile(candidate))
			return candidate;
	}
	return "";
}

unittest
{
	findExecutable("sh").length.should.be.greaterThan(0);
	findExecutable("this-binary-should-not-exist-zzz").should.equal("");
	findExecutable("/bin/no-such-file").should.equal("");
}
