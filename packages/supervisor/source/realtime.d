module realtime;

import core.time : Duration, MonoTime, minutes;

import std.conv : to;
import std.process : environment;

import vibe.core.core : sleep;
import vibe.data.json : deserializeJson, parseJsonString;
import vibe.http.server : HTTPListener;

import agentcore.core.env : defaultRealtimePort, envConversationPin, envModel, envRealtimeIdleMs,
	envRealtimeNextArgv, envRealtimePort, envRealtimePrompt, envRealtimeStyle, envRealtimeToken, envSelect;
import agentcore.core.exec : findExecutable;
import agentcore.core.log : logError;
import agentcore.crds.output_sink : OutputSink;
import agentcore.output.event : EventSource, sourceFromEnv;
import agentcore.output.lifecycle : LifecycleEvent, Phase, Status, toJson;
import agentcore.output.output : sinksFromEnv;
import agentcore.output.selectmatcher : parseSelectors, selected;
import agentcore.output.session : sessionEvent;
import agentcore.vendors.base.agent : StdinSession;
import agentcore.vendors.realtime : turnArgv;
import agentcore.vendors.select : agentForModel;
import promptserver : listenPrompts, RealtimeSession;
import sink : emit;
import supervise : agentFailed, AgentProcess, announceSession, deadlineExitCode, deadlineFromEnv, drainDeadline,
	exitGraceFromEnv, finishRun, forceDown, g_realtime, g_terminate, msFromEnv, pollInterval, waitFlag;
import turnqueue : idleExpired;

version (unittest) import fluent.asserts;

/// How long a realtime session waits for a prompt when `AGENT_REALTIME_IDLE_MS` is unset.
private enum defaultIdle = 15.minutes;

/// Supervise a realtime session of the agent `argv` describes: serve prompts over HTTP,
/// run them one turn at a time — on the stdin of one long-lived process, or as one
/// process per turn — and end when the session idles out, is closed, is signalled or
/// hits its deadline. Its conversation is saved under the session id either way.
int superviseRealtime(string[] argv)
{
	g_realtime = true;
	const sinks = sinksFromEnv();
	const source = sourceFromEnv();
	const selectors = parseSelectors(environment.get(envSelect, ""));
	const model = environment.get(envModel, "");
	const vendor = agentForModel(model);
	const provider = vendor.name;
	const stdinStyle = environment.get(envRealtimeStyle, "") == "stdin";
	const pin = environment.get(envConversationPin, "");

	// Read, then drop, the bearer: the agent and everything it spawns inherit this
	// environment, and must not be able to prompt their own session.
	auto session = new RealtimeSession(environment.get(envRealtimeToken, ""));
	environment.remove(envRealtimeToken);
	session.sessionId = pin;

	if (session.token.length == 0)
		return refuse(sinks, source, "realtime mode needs " ~ envRealtimeToken, "token");
	if (findExecutable(argv[0]).length == 0)
		return refuse(sinks, source, "agent not found: " ~ argv[0], "not-found");
	auto stdinSession = cast(const StdinSession) vendor;
	if (stdinStyle && stdinSession is null)
		return refuse(sinks, source, provider ~ " cannot run a stdin session", "spawn");

	void onLine(string payload) nothrow
	{
		emit(sinks, source, payload, selected(selectors, provider, payload));
		announceSession(sinks, source, provider, payload, session.sessionId);
	}

	HTTPListener listener;
	try
		listener = listenPrompts(portFromEnv(), session);
	catch (Exception e)
		return refuse(sinks, source, "cannot serve prompts: " ~ e.msg, "listen");

	AgentProcess agent;
	if (stdinStyle)
	{
		try
			agent = new AgentProcess(argv, true, provider, &onLine);
		catch (Exception e)
			return refuse(sinks, source, "failed to start agent: " ~ e.msg, "spawn");
	}

	emit(sinks, source, LifecycleEvent(Phase.agent, Status.started).toJson);
	if (session.sessionId.length)
		emit(sinks, source, sessionEvent(session.sessionId));
	if (!stdinStyle && vendor.stateDir.length == 0)
		emit(sinks, source, noContinuity.toJson);

	const firstPrompt = environment.get(envRealtimePrompt, "");
	if (firstPrompt.length)
		session.queue.push(firstPrompt);

	const grace = exitGraceFromEnv();
	const deadline = deadlineFromEnv();
	const idle = msFromEnv(envRealtimeIdleMs, defaultIdle);
	const next = nextArgvFromEnv();
	const started = MonoTime.currTime;
	AgentProcess turnProcess;
	int code;

	while (true)
	{
		sleep(pollInterval);
		const now = MonoTime.currTime;
		if (g_terminate)
			break;
		if (deadline > Duration.zero && now - started >= deadline)
		{
			logError("[supervisor] run deadline expired; ending the realtime session");
			code = deadlineExitCode;
			break;
		}
		if (stdinStyle && agent.processExited)
		{
			logError("[supervisor] the agent exited during the realtime session");
			code = agent.processCode;
			break;
		}

		if (session.queue.running)
		{
			bool ok;
			const over = stdinStyle ? stdinTurnOver(agent, ok) : processTurnOver(turnProcess, grace, ok);
			if (over)
			{
				emit(sinks, source, turnEvent(session.queue.started, "completed", ok));
				session.queue.finish();
				session.lastActivity = MonoTime.currTime;
			}
		}

		if (session.queue.ready)
		{
			const prompt = session.queue.start();
			emit(sinks, source, turnEvent(session.queue.started, "started"));
			if (stdinStyle)
				sendTurn(agent, stdinSession.userTurn(prompt));
			else
				turnProcess = spawnTurn(turnArgv(session.sessionId.length && next.length ? next : argv,
					prompt, session.sessionId), provider, &onLine);
		}

		if (session.closing && session.queue.drained)
			break;
		if (idleExpired(session.queue.drained, now - session.lastActivity, idle))
			break;
	}

	session.ending = true;
	listener.stopListening();
	if (stdinStyle)
		stopSession(agent, grace);
	else if (turnProcess !is null && !turnProcess.processExited)
	{
		forceDown(grace, turnProcess.processExited);
		cast(void) waitFlag(turnProcess.readerDone, drainDeadline);
	}

	finishRun(sinks, source, code, session.sessionId.length ? session.sessionId : pin, session.sessionId);
	assert(0, "unreachable");
}

/// Report a session that cannot start: log `message`, raise an agent `failed` event with
/// `reason`, and return the exit code.
private int refuse(const OutputSink[] sinks, in EventSource source, string message, string reason)
{
	logError("[supervisor] " ~ message);
	emit(sinks, source, agentFailed(reason).toJson);
	return 1;
}

/// Whether the running stdin turn ended, with `ok` its verdict. Clears the terminal flag
/// so the next turn's result is seen.
private bool stdinTurnOver(AgentProcess agent, out bool ok)
{
	if (!agent.terminalSeen)
		return false;
	ok = agent.runOk;
	agent.terminalSeen = false;
	return true;
}

/// Whether the running per-turn process ended, with `ok` its verdict. A process that
/// emitted its terminal event but lingers past `grace` is forced down, like a one-shot run.
private bool processTurnOver(AgentProcess turn, Duration grace, out bool ok)
{
	if (turn is null)
		return true;
	if (!turn.processExited && !turn.terminalSeen)
		return false;
	const exitedOnOwn = turn.processExited || waitFlag(turn.processExited, grace);
	if (!exitedOnOwn)
		forceDown(grace, turn.processExited);
	cast(void) waitFlag(turn.readerDone, drainDeadline);
	ok = exitedOnOwn ? turn.processCode == 0 : turn.runOk;
	return true;
}

/// Write one user turn to the session's stdin. A failed write means the agent is gone,
/// which the loop sees as its exit.
private void sendTurn(AgentProcess agent, string line)
{
	try
		agent.pipes.stdin.write(line ~ "\n");
	catch (Exception e)
		logError("[supervisor] cannot write the turn to the agent: " ~ e.msg);
}

/// Spawn one turn's process, or null when it cannot start (the turn then ends failed).
private AgentProcess spawnTurn(string[] argv, string provider, void delegate(string) nothrow onLine)
{
	try
		return new AgentProcess(argv, false, provider, onLine);
	catch (Exception e)
	{
		logError("[supervisor] failed to start the turn: " ~ e.msg);
		return null;
	}
}

/// End a stdin session: close its stdin so the CLI exits on its own, force it down after
/// `grace`, then let the reader drain.
private void stopSession(AgentProcess agent, Duration grace)
{
	try
		agent.pipes.stdin.close();
	catch (Exception e)
		logError("[supervisor] closing the agent's stdin failed: " ~ e.msg);
	if (!waitFlag(agent.processExited, grace))
		forceDown(grace, agent.processExited);
	cast(void) waitFlag(agent.readerDone, drainDeadline);
}

/// The argv for turns after a session id is known, or null when every turn uses the first argv.
private string[] nextArgvFromEnv()
{
	const raw = environment.get(envRealtimeNextArgv, "");
	return raw.length ? deserializeJson!(string[])(parseJsonString(raw)) : null;
}

private ushort portFromEnv()
{
	const raw = environment.get(envRealtimePort, "");
	return raw.length ? raw.to!ushort : cast(ushort) defaultRealtimePort;
}

/// Raised once when every turn starts fresh because the vendor keeps no conversation state.
private enum noContinuity = LifecycleEvent(Phase.agent, Status.running, "", "no-continuity");

/// The `{"kind":"turn",…}` event marking turn `turn` as `status`; a completed turn carries `ok`.
string turnEvent(size_t turn, string status, bool ok = true) nothrow
{
	const head = `{"kind":"turn","turn":` ~ turn.to!string ~ `,"status":"` ~ status ~ `"`;
	return status == "completed" ? head ~ `,"ok":` ~ (ok ? "true" : "false") ~ "}" : head ~ "}";
}

unittest // a started turn carries its number, a completed one also its verdict
{
	[turnEvent(1, "started"), turnEvent(2, "completed", false)].should.equal([
		`{"kind":"turn","turn":1,"status":"started"}`,
		`{"kind":"turn","turn":2,"status":"completed","ok":false}`,
	]);
}
