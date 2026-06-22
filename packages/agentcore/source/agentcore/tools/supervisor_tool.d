module agentcore.tools.supervisor_tool;

import agentcore.kube.bundle : bundleBinDir, supervisorPath, supervisorStageSource;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.tool : Tool;

/// Stage the supervisor binary (baked into the agent image at a fixed path) into
/// the shared bundle so the main container can exec it as PID 1. Active on every
/// run and idempotent across init-container retries. A single guarded shell step:
/// it stages only when the supervisor is actually present (always true in the
/// agent image; absent on host-based init tests, where it skips cleanly instead of
/// failing on a missing source or an unwritable bundle root). The destination is
/// the shared `supervisorPath`, so it can never drift from the Job's command.
final class SupervisorTool : Tool
{
	override string name() const @safe
	{
		return "supervisor";
	}

	override string[] requires() const @safe
	{
		return ["sh"];
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		return [[
			"sh", "-c",
			"if [ -f " ~ supervisorStageSource ~ " ]; then mkdir -p " ~ bundleBinDir
				~ " && cp " ~ supervisorStageSource ~ " " ~ supervisorPath
				~ " && chmod +x " ~ supervisorPath ~ "; fi",
		]];
	}
}

version (unittest) import fluent.asserts;
version (unittest) import std.algorithm.searching : canFind;

@safe unittest
{
	auto tool = new SupervisorTool;
	tool.name.should.equal("supervisor");
	tool.requires.should.equal(["sh"]);

	InitContext ctx;
	auto steps = tool.steps(ctx);
	steps.length.should.equal(1);
	steps[0][0].should.equal("sh");
	steps[0][1].should.equal("-c");
	// The guarded script stages from the image path to the shared bundle path.
	steps[0][2].canFind("[ -f /usr/local/lib/ai-agent/ai-agent-supervisor ]").should.equal(true);
	steps[0][2].canFind("cp /usr/local/lib/ai-agent/ai-agent-supervisor /lore/bin/ai-agent-supervisor")
		.should.equal(true);

	// Staged on every run, whatever the model.
	ctx.model = "gpt-5-codex";
	tool.steps(ctx).length.should.equal(1);
}
