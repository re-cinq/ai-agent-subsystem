module app;

import std.stdio : writeln, writefln;
import std.process : environment;

import agentcore;

int main()
{
	const ns = environment.get("NAMESPACE", "ai-agents");
	const healthPort = environment.get("HEALTH_PORT", "8081");
	const agentImage = environment.get("AGENT_IMAGE", "ghcr.io/re-cinq/ai-agent:latest");

	writefln("ai-agent-controller: namespace=%s health=:%s agentImage=%s",
		ns, healthPort, agentImage);

	// Smoke-exercise the shared reconcile core so the link is real.
	const d = decide(Phase.pending, true, false, JobOutcome.init);
	writefln("reconcile self-check: pending -> %s (%s)", cast(string) d.phase, d.kind);

	writeln("watch + poll loop not yet implemented (bootstrap)");
	return 0;
}
