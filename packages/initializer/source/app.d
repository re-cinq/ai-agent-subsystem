module app;

import core.sys.posix.signal : signal, SIGPIPE, SIG_IGN;

import std.process : environment;

import agentcore.core.env : envDelivery;
import agentcore.delivery.plan : parsePlan;
import agentcore.tools.mcp_settings : writeMcpSettings;
import courier : courier;
import provision : contextFromEnv, provision;

/// The init container's entrypoint: read what the controller injected, provision
/// the environment, and exit with the result (0 success, non-zero fails the Pod
/// before the supervisor container starts). Re-entered by one of its own steps as
/// `ai-agent-init mcp-settings <file> <key> <servers json>` to merge a run's MCP
/// servers into the CLI's settings file, work the slim init image has no tool for.
/// Run as `ai-agent-init courier` it is a pull request delivery's courier container.
int main(string[] args)
{
	// `dub test` runs main after the module unittests; return before provisioning so
	// the test binary exits 0 instead of attempting a real clone/install.
	version (unittest)
		return 0;

	if (args.length == 5 && args[1] == "mcp-settings")
	{
		writeMcpSettings(args[2], args[3], args[4]);
		return 0;
	}

	// Ignore SIGPIPE (as the supervisor does): notify writes the curl config to a child's
	// stdin, and if curl exits before reading it (killed, or a config it rejects), the
	// write would otherwise raise SIGPIPE and kill PID 1 of the init container — turning a
	// retryable sink failure into a fatal Pod init failure. Ignored, the write instead
	// fails with a catchable ErrnoException that curlOnce turns into a clean retry.
	signal(SIGPIPE, SIG_IGN);

	if (args.length == 2 && args[1] == "courier")
		return courier(parsePlan(environment.get(envDelivery, "")));

	return provision(contextFromEnv());
}
