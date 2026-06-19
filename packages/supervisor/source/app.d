module app;

import std.algorithm.searching : countUntil;

import vibe.core.core : runEventLoop, runTask, exitEventLoop;

import agentcore.log : logError;
import supervise : supervise;

private __gshared int g_exitCode = 1;

int main(string[] args)
{
	// The controller invokes the supervisor as `ai-agent-supervisor -- <agent argv>`.
	const sep = args.countUntil("--");
	if (sep == -1 || sep + 1 >= args.length)
	{
		logError("usage: ai-agent-supervisor -- <agent> [args...]");
		return 2;
	}

	auto agentArgv = args[sep + 1 .. $].dup;

	runTask(() nothrow {
		try
			g_exitCode = supervise(agentArgv);
		catch (Exception e)
		{
			logError("[supervisor] " ~ e.msg);
			g_exitCode = 1;
		}

		try
			exitEventLoop();
		catch (Exception e)
			logError("[supervisor] exitEventLoop failed: " ~ e.msg);
	});

	runEventLoop();

	return g_exitCode;
}
