module supervise;

import core.stdc.signal : signal, SIG_IGN, SIGINT, SIGTERM;
import core.sys.posix.signal : kill, SIGKILL, SIGPIPE;
import core.sys.posix.unistd : _exit;
import core.sys.posix.sys.types : pid_t;
import core.time : Duration, msecs;

import vibe.core.core : disableDefaultSignalHandlers, runTask, sleep;
import vibe.core.process : pipeProcess, Redirect, ProcessPipes;
import vibe.stream.operations : readLine;

import std.conv : to;
import std.process : environment;

import agentcore.vendors.select : agentForModel;
import agentcore.core.env : defaultExitGraceMs, envExitGraceMs, envModel, envSelect;
import agentcore.output.event : sourceFromEnv;
import agentcore.core.exec : findExecutable;
import agentcore.output.lifecycle : LifecycleEvent, Phase, Status, toJson;
import agentcore.core.log : logError;
import agentcore.output.output : sinksFromEnv;
import agentcore.output.selectmatcher : parseSelectors, selected;
import agentcore.output.terminal : terminalFor;
import sink : emit;

/// How often the wait loop polls the agent's exit / terminal-event state.
private enum pollInterval = 20.msecs;

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
	const sinks = sinksFromEnv();
	const source = sourceFromEnv();
	const selectors = parseSelectors(environment.get(envSelect, ""));
	const provider = agentForModel(environment.get(envModel, "")).name;
	const grace = exitGraceFromEnv();

	if (findExecutable(agentArgv[0]).length == 0)
	{
		logError("[supervisor] agent not found: " ~ agentArgv[0]);
		emit(sinks, source, agentFailed("not-found").toJson);
		return 1;
	}

	ProcessPipes pipes;
	try
		pipes = pipeProcess(agentArgv, Redirect.stdout);
	catch (Exception e)
	{
		logError("[supervisor] failed to start agent: " ~ e.msg);
		emit(sinks, source, agentFailed("spawn").toJson);
		return 1;
	}

	g_childPid = pipes.process.pid;
	emit(sinks, source, LifecycleEvent(Phase.agent, Status.started).toJson);

	// The agent's terminal event, observed on stdout. Some agent CLIs emit this
	// final event and then fail to exit (a lingering worker keeps the process
	// alive), so the terminal event — not process exit — is the authoritative
	// "work done" signal.
	bool terminalSeen = false;
	bool runOk = false;

	// Stream stdout in its own task so the agent's *process exit* ends the run,
	// not stdout EOF: a stray child that inherits and holds stdout open would
	// otherwise keep the pipe from ever reaching EOF and hang the loop.
	runTask(() nothrow {
		try
		{
			while (!pipes.stdout.empty)
			{
				auto raw = pipes.stdout.readLine(size_t.max, "\n");
				if (raw.length == 0)
					continue;
				const payload = cast(string) raw.idup;
				emit(sinks, source, payload, selected(selectors, provider, payload));
				if (!terminalSeen)
				{
					const terminal = terminalFor(provider, payload);
					if (terminal.reached)
					{
						terminalSeen = true;
						runOk = terminal.ok;
					}
				}
			}
		}
		catch (Exception)
		{
			// stdout closed (normal EOF) or the reader was interrupted on exit.
		}
	});

	// Reap the agent in its own task so the wait loop can react to the terminal
	// event without blocking on a process that may never exit on its own.
	int processCode = 1;
	bool processExited = false;
	runTask(() nothrow {
		try
			processCode = pipes.process.wait();
		catch (Exception)
			processCode = 1;
		processExited = true;
	});

	const code = awaitOutcome(grace, processExited, processCode, terminalSeen, runOk);

	// Brief grace for the reader to flush output buffered right up to the terminal
	// event (emitEvent writes + flushes stdout per event as it reads).
	sleep(100.msecs);
	emit(sinks, source, agentExit(code).toJson);

	// Hard-exit instead of joining the reader/waiter and unwinding the event loop.
	// A stray grandchild of the agent (the real Claude CLI spawns workers) can inherit
	// and hold the stdout pipe open, so the reader never reaches EOF and a join would
	// block until the Job's activeDeadlineSeconds — the run pod then never terminates
	// even though the work is done (#58). _exit guarantees PID 1 dies so the pod and
	// Job finish promptly; stdout is already flushed per event, and any grandchildren
	// die with the container once PID 1 is gone.
	_exit(code);
	assert(0, "unreachable");
}

/// Block until the agent's run is over, returning the exit code to report. The run
/// ends when the process exits on its own (the normal path — its real exit code is
/// used) or when the agent emits its terminal event but the process lingers. In the
/// latter case the process is given `grace` to exit cleanly, then SIGTERM and finally
/// SIGKILL force it down so the pod can terminate, and the code reflects the agent's
/// own success/failure rather than the signal that killed it.
private int awaitOutcome(Duration grace, ref bool processExited, ref int processCode,
	ref bool terminalSeen, ref bool runOk)
{
	while (!processExited && !terminalSeen)
		sleep(pollInterval);

	// The process exited on its own (the normal path, and the mock/Codex path):
	// its real exit code is authoritative.
	if (processExited)
		return processCode;

	// The agent signalled it is done but the process is still up. Give it the grace
	// window to exit cleanly first — if it does, that exit code is still its own.
	if (waitExit(processExited, grace))
		return processCode;

	// It is lingering. Force it down (SIGTERM, then SIGKILL) so the pod can
	// terminate. Any exit code now reflects the signal we sent, not the agent's
	// work, so the terminal event's success/failure is authoritative.
	if (g_childPid > 0)
		kill(g_childPid, SIGTERM);
	if (!waitExit(processExited, grace) && g_childPid > 0)
		kill(g_childPid, SIGKILL);
	cast(void) waitExit(processExited, grace);
	return runOk ? 0 : 1;
}

/// Poll `processExited` up to `limit`, yielding between checks; true if the process
/// exited within the window.
private bool waitExit(ref bool processExited, Duration limit)
{
	Duration waited;
	while (!processExited && waited < limit)
	{
		sleep(pollInterval);
		waited += pollInterval;
	}
	return processExited;
}

/// The terminal-event grace window from the environment, falling back to the
/// default when unset or unparseable.
private Duration exitGraceFromEnv()
{
	try
	{
		const raw = environment.get(envExitGraceMs, "");
		if (raw.length)
		{
			const ms = raw.to!int;
			if (ms > 0)
				return ms.msecs;
		}
	}
	catch (Exception)
	{
	}
	return defaultExitGraceMs.msecs;
}

/// An agent-phase `failed` event the supervisor itself raises (the agent never ran):
/// `not-found` when the binary is missing, `spawn` when the process can't start.
private LifecycleEvent agentFailed(string reason)
{
	LifecycleEvent ev = {phase: Phase.agent, status: Status.failed};
	ev.reason = reason;
	return ev;
}

/// The agent-phase terminal event: `succeeded` on a clean exit, `failed` otherwise,
/// either way carrying the agent's exit code so a hook can branch on it.
private LifecycleEvent agentExit(int code)
{
	LifecycleEvent ev = {
		phase: Phase.agent, status: code == 0 ? Status.succeeded : Status.failed
	};
	ev.exitCode = code;
	return ev;
}
