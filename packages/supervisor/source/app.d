module app;

import std.algorithm.searching : countUntil;

import vibe.core.core : runEventLoop, runTask, exitEventLoop;

import agentcore.core.log : logError;
import supervise : supervise, installSignalForwarding;

private __gshared int g_exitCode = 1;

int main(string[] args)
{
	// `dub test` builds this executable with -unittest and runs main after the module
	// unittests; return before the reconcile/supervise work so the test binary exits 0.
	version (unittest)
		return 0;

	// The controller invokes the supervisor as `ai-agent-supervisor -- <agent argv>`.
	const sep = args.countUntil("--");
	if (sep == -1 || sep + 1 >= args.length)
	{
		logError("usage: ai-agent-supervisor -- <agent> [args...]");
		return 2;
	}

	auto agentArgv = args[sep + 1 .. $].dup;

	installSignalForwarding();

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
