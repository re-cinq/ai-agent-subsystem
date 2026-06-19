module supervise;

import std.process : environment;
import std.stdio : stdout;

import vibe.core.process : pipeProcess, Redirect, ProcessPipes;
import vibe.stream.operations : readLine;

import agentcore.env : envNotifyUrl;
import agentcore.log : logError;
import sink : postLine;

/// Supervise `agentArgv` (built by the controller from the recipe): spawn it,
/// stream its newline-delimited JSON output to stdout (and the optional http
/// sink), and return its exit code. Runs inside a vibe task so the sink's HTTP
/// client shares the event loop. (Auth is the agent's own concern — the
/// controller injects provider API keys as env vars.)
int supervise(string[] agentArgv)
{
	immutable notifyUrl = environment.get(envNotifyUrl, "");

	ProcessPipes pipes;
	try
		pipes = pipeProcess(agentArgv, Redirect.stdout);
	catch (Exception e)
	{
		logError("[supervisor] failed to start agent: " ~ e.msg);
		return 1;
	}

	while (!pipes.stdout.empty)
	{
		ubyte[] raw;

		try
			raw = pipes.stdout.readLine(size_t.max, "\n");
		catch (Exception)
			break;

		if (raw.length == 0)
			continue;

		const line = cast(string) raw.idup;

		stdout.writeln(line);
		stdout.flush();

		if (notifyUrl.length)
			postLine(notifyUrl, line);
	}

	return pipes.process.wait();
}
