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
import std.file : exists;
import agentcore.core.env : defaultExitGraceMs, defaultWorkspace, envConversationPin,
	envConversationSource, envDeadlineMs, envExitGraceMs,
	envModel, envSelect, envWatch, envWorkspace;
import agentcore.crds.output_sink : OutputSink;
import agentcore.output.event : EventSource, sourceFromEnv;
import agentcore.core.exec : findExecutable;
import agentcore.output.fileevent : parseWatches, readWatched, toJson;
import agentcore.output.lifecycle : LifecycleEvent, Phase, Status, toJson;
import agentcore.core.log : logError;
import agentcore.output.output : sinksFromEnv;
import agentcore.output.selectmatcher : parseSelectors, selected;
import agentcore.output.terminal : terminalFor;
import archive : collect, tarGz;
import sink : emit, postConversation;

/// How often the wait loop polls the agent's exit / terminal-event state.
private enum pollInterval = 20.msecs;

/// Defensive ceiling on a single stdout event line, so a malformed agent stream with no
/// newline can't buffer without bound. Well above any real stream-json event; a line past
/// it throws, the reader task stops (the run still ends via process exit), rather than
/// growing memory until the pod is OOM-killed.
private enum maxEventLineBytes = 16 * 1024 * 1024;

/// Cap on how long the final stdout drain waits for the reader to reach EOF before the
/// hard exit — long enough to flush a large final burst, short enough that a grandchild
/// holding the pipe open can't stall pod teardown.
private enum drainDeadline = 2000.msecs;

/// Prefix on every forwarded agent stderr line, so the pod log distinguishes the agent's
/// diagnostics from the supervisor's own and from the JSONL events on stdout.
private enum agentStderrTag = "[agent] ";

/// Exit code reported when the run deadline expires — GNU `timeout`'s convention, and
/// distinct from any code the agent itself could return.
enum deadlineExitCode = 124;

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
	const deadline = deadlineFromEnv();

	if (findExecutable(agentArgv[0]).length == 0)
	{
		logError("[supervisor] agent not found: " ~ agentArgv[0]);
		emit(sinks, source, agentFailed("not-found").toJson);
		return 1;
	}

	ProcessPipes pipes;
	try
		pipes = pipeProcess(agentArgv, Redirect.stdout | Redirect.stderr);
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
	bool readerDone = false; // the reader drained stdout to EOF (no output left to flush)

	// Stream stdout in its own task so the agent's *process exit* ends the run,
	// not stdout EOF: a stray child that inherits and holds stdout open would
	// otherwise keep the pipe from ever reaching EOF and hang the loop.
	runTask(() nothrow {
		try
		{
			while (!pipes.stdout.empty)
			{
				auto raw = pipes.stdout.readLine(maxEventLineBytes, "\n");
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
		readerDone = true;
	});

	// Stream stderr too, tagged. Left inherited it lands raw in the pod log, interleaved
	// with the JSONL event stream the controller caps into status.output — where a
	// consumer parsing events cannot tell a crash trace from a malformed event. It is
	// also the only place an agent CLI prints auth failures, rate limits and stack
	// traces, so a failed run had an exit code and nothing to read (#47).
	runTask(() nothrow {
		try
		{
			while (!pipes.stderr.empty)
			{
				auto raw = pipes.stderr.readLine(maxEventLineBytes, "\n");
				if (raw.length)
					logError(agentStderrTag ~ cast(string) raw.idup);
			}
		}
		catch (Exception)
		{
			// stderr closed (normal EOF) or the reader was interrupted on exit.
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

	const code = awaitOutcome(grace, deadline, processExited, processCode, terminalSeen, runOk);

	// Let the reader flush output buffered right up to the terminal event before we
	// hard-exit. Wait for it to drain to EOF rather than a blind fixed sleep (which
	// could cut off a large final burst), but cap the wait: a stray grandchild can hold
	// stdout open forever, and pod teardown must not block on that (#58).
	cast(void) waitFlag(readerDone, drainDeadline);

	// Raise the recipe's declared artifacts BEFORE the terminal event: a consumer that
	// treats agent/succeeded|failed as end-of-stream must still receive them. The agent
	// has exited and the workspace volume is still mounted, so this is the only point
	// where a file it produced can be read at all (#188).
	emitWatchedFiles(sinks, source);
	// Save this run's conversation so a later round can continue it. Before the
	// terminal event for the same reason as the artifacts: a consumer that stops
	// there must not miss it, and the state dir only exists while this pod does.
	saveConversation();
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

/// Read every declared artifact and raise it as a named `kind:"file"` event on the
/// run's normal sinks. Best-effort by construction: a refused path is skipped, and a
/// missing or oversized file still raises an event carrying the reason, so a consumer
/// hears "the agent produced nothing" instead of waiting forever. Never throws — it
/// runs on the terminal path, where an exception would cost the exit event too.
private void emitWatchedFiles(const OutputSink[] sinks, in EventSource source) nothrow
{
	try
	{
		const workspace = environment.get(envWorkspace, defaultWorkspace);
		foreach (watch; parseWatches(environment.get(envWatch, "")))
		{
			const ev = readWatched(watch, workspace);
			if (!ev.isNull)
				emit(sinks, source, ev.get.toJson);
		}
	}
	catch (Exception e)
		logError("[watch] " ~ e.msg);
}

/// Archive the vendor's conversation state directory and POST it to the run's
/// conversation registry, so a later run can continue this one.
///
/// Saved under `pin` rather than the id being resumed: that is what makes this a
/// FORK — the run it continued is left intact and independently resumable, which is
/// what lets a caller rewind to an earlier run rather than only the latest.
///
/// Silent no-op unless the recipe declared a source, a pin, and the vendor reports a
/// state dir. Best-effort throughout: a failed save costs the NEXT run its continuity,
/// never this one its result.
private void saveConversation() nothrow
{
	try
	{
		const src = environment.get(envConversationSource, "");
		const pin = environment.get(envConversationPin, "");
		const dir = agentForModel(environment.get(envModel, "")).stateDir;

		if (src.length == 0 || pin.length == 0 || dir.length == 0)
			return;

		const home = environment.get("HOME", "");
		const path = home ~ "/" ~ dir;

		if (!path.exists)
			return;

		// Archived in-process rather than by shelling out to `tar`: this binary is
		// exec'd by the Station's OWN base image, and a supported base ships no tar
		// (amazonlinux:2023), where the spawn failed and the run still reported
		// success — continuity that saved nothing. The bytes stay binary throughout,
		// nowhere near a string or an event line.
		postConversation(src ~ "/" ~ pin, tarGz(collect(home, dir)));
	}
	catch (Exception e)
		logError("[conversation] save failed: " ~ e.msg);
}

/// Block until the agent's run is over, returning the exit code to report. The run
/// ends when the process exits on its own (the normal path — its real exit code is
/// used) or when the agent emits its terminal event but the process lingers. In the
/// latter case the process is given `grace` to exit cleanly, then SIGTERM and finally
/// SIGKILL force it down so the pod can terminate, and the code reflects the agent's
/// own success/failure rather than the signal that killed it. An agent that does
/// neither is forced down at `deadline` so the caller can still report a terminal event.
private int awaitOutcome(Duration grace, Duration deadline, ref bool processExited,
	ref int processCode, ref bool terminalSeen, ref bool runOk)
{
	// Bounded by the run deadline: with neither an exit nor a terminal event this would
	// otherwise spin until the kubelet killed the pod at the Job's activeDeadlineSeconds,
	// taking the agentExit event with it and leaving downstream with no terminal at all.
	if (!waitOutcome(deadline, processExited, terminalSeen))
	{
		logError("[supervisor] run deadline expired with no terminal event; forcing the agent down");
		forceDown(grace, processExited);
		return deadlineExitCode;
	}

	// The process exited on its own (the normal path, and the mock/Codex path):
	// its real exit code is authoritative.
	if (processExited)
		return reportedExitCode(true, processCode, runOk);

	// The agent signalled it is done but the process is still up. Give it the grace
	// window to exit cleanly first — if it does, that exit code is still its own.
	if (waitFlag(processExited, grace))
		return reportedExitCode(true, processCode, runOk);

	// It is lingering. Force it down so the pod can terminate. Any exit code now
	// reflects the signal we sent, not the agent's work, so the terminal event's
	// success/failure is authoritative.
	forceDown(grace, processExited);
	return reportedExitCode(false, processCode, runOk);
}

/// Escalate SIGTERM -> SIGKILL until the agent is gone, allowing `grace` at each step.
private void forceDown(Duration grace, ref bool processExited)
{
	if (g_childPid > 0)
		kill(g_childPid, SIGTERM);
	if (!waitFlag(processExited, grace) && g_childPid > 0)
		kill(g_childPid, SIGKILL);
	cast(void) waitFlag(processExited, grace);
}

/// Poll until the agent exits or emits its terminal event, bounded by `limit` when it is
/// positive (a non-positive limit means unbounded). True if either happened in time.
private bool waitOutcome(Duration limit, ref bool processExited, ref bool terminalSeen)
{
	Duration waited;
	while (!processExited && !terminalSeen && (limit <= Duration.zero || waited < limit))
	{
		sleep(pollInterval);
		waited += pollInterval;
	}
	return processExited || terminalSeen;
}

/// The exit code to report. A process that exited on its own (or within its grace
/// window) carries its real code. A process we had to SIGTERM/SIGKILL exits with the
/// signal's code, which says nothing about the work — so the agent's own terminal-event
/// verdict (`runOk`) is authoritative there instead.
int reportedExitCode(bool exitedOnOwn, int processCode, bool runOk) @safe pure nothrow
{
	return exitedOnOwn ? processCode : (runOk ? 0 : 1);
}

/// Poll a shared `flag` up to `limit`, yielding between checks; true if it became set
/// within the window. Used both for "the process exited" and "the reader drained".
private bool waitFlag(ref bool flag, Duration limit)
{
	Duration waited;
	while (!flag && waited < limit)
	{
		sleep(pollInterval);
		waited += pollInterval;
	}
	return flag;
}

/// A positive-millisecond duration read from `name`, falling back to `whenUnset` when
/// the variable is missing, non-numeric or non-positive.
private Duration msFromEnv(string name, Duration whenUnset)
{
	try
	{
		const raw = environment.get(name, "");
		if (raw.length)
		{
			const ms = raw.to!long;
			if (ms > 0)
				return ms.msecs;
		}
	}
	catch (Exception)
	{
	}
	return whenUnset;
}

/// The terminal-event grace window from the environment, falling back to the
/// default when unset or unparseable.
private Duration exitGraceFromEnv()
{
	return msFromEnv(envExitGraceMs, defaultExitGraceMs.msecs);
}

/// The run deadline from the environment. Absent or unparseable means no supervisor-side
/// deadline — the Job's activeDeadlineSeconds stays the only bound, which is the
/// pre-#48 behaviour and the right default for a supervisor run outside a Job.
private Duration deadlineFromEnv()
{
	return msFromEnv(envDeadlineMs, Duration.zero);
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

version (unittest) import fluent.asserts;

@safe unittest
{
	// A process that exits on its own reports its real code, success or failure.
	reportedExitCode(true, 0, false).should.equal(0);
	reportedExitCode(true, 42, false).should.equal(42);
	// A process we had to kill: the signal's code is meaningless, so the terminal
	// event's verdict wins — 0 when the run succeeded, 1 when it failed.
	reportedExitCode(false, 137, true).should.equal(0);
	reportedExitCode(false, 137, false).should.equal(1);
}

unittest
{
	// agentExit maps the code to succeeded/failed and carries the code.
	auto ok = agentExit(0);
	ok.status.should.equal(Status.succeeded);
	ok.exitCode.get.should.equal(0);

	auto bad = agentExit(3);
	bad.phase.should.equal(Phase.agent);
	bad.status.should.equal(Status.failed);
	bad.exitCode.get.should.equal(3);
}

unittest
{
	// An outcome already reached returns at once, without waiting the limit out.
	bool exited = true;
	bool terminal = false;
	waitOutcome(1.msecs, exited, terminal).should.equal(true);

	exited = false;
	terminal = true;
	waitOutcome(1.msecs, exited, terminal).should.equal(true);
}

unittest
{
	// A deadline kill still reports a terminal event, and it reports failure carrying
	// the timeout code — the run produced no verdict of its own (#48).
	auto ev = agentExit(deadlineExitCode);
	ev.phase.should.equal(Phase.agent);
	ev.status.should.equal(Status.failed);
	ev.exitCode.get.should.equal(124);
}

unittest
{
	// agentFailed is an agent-phase failure the supervisor raises itself, carrying the slug.
	auto ev = agentFailed("not-found");
	ev.phase.should.equal(Phase.agent);
	ev.status.should.equal(Status.failed);
	ev.reason.should.equal("not-found");
}

unittest
{
	scope (exit)
		environment.remove(envExitGraceMs);

	// A positive value parses to that many milliseconds.
	environment[envExitGraceMs] = "1234";
	exitGraceFromEnv().should.equal(1234.msecs);

	// Unset, non-numeric, and non-positive all fall back to the default.
	environment.remove(envExitGraceMs);
	exitGraceFromEnv().should.equal(defaultExitGraceMs.msecs);
	environment[envExitGraceMs] = "abc";
	exitGraceFromEnv().should.equal(defaultExitGraceMs.msecs);
	environment[envExitGraceMs] = "0";
	exitGraceFromEnv().should.equal(defaultExitGraceMs.msecs);
}

unittest
{
	scope (exit)
		environment.remove(envDeadlineMs);

	// A positive value is the run deadline; a 30-minute Job window renders 1_790_000.
	environment[envDeadlineMs] = "1790000";
	deadlineFromEnv().should.equal(1_790_000.msecs);

	// Unset, non-numeric and non-positive mean no supervisor-side deadline, leaving the
	// Job's activeDeadlineSeconds as the only bound.
	environment.remove(envDeadlineMs);
	deadlineFromEnv().should.equal(Duration.zero);
	environment[envDeadlineMs] = "abc";
	deadlineFromEnv().should.equal(Duration.zero);
	environment[envDeadlineMs] = "-1";
	deadlineFromEnv().should.equal(Duration.zero);
}
