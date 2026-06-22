module agentcore.supervisor_tool;

import agentcore.bundle : bundleBinDir, supervisorPath, supervisorStageSource;
import agentcore.initcontext : InitContext;
import agentcore.tool : Tool;

/// Stage the supervisor binary (baked into the agent image at a fixed path) into
/// the shared bundle so the main container can exec it as PID 1. Active on every
/// run — the supervisor is always needed — and idempotent across init-container
/// retries (`cp` overwrites, `mkdir -p` is a no-op). The destination is the shared
/// `supervisorPath`, so it can never drift from where the Job's command points.
final class SupervisorTool : Tool
{
	override string name() const @safe
	{
		return "supervisor";
	}

	override string[] requires() const @safe
	{
		return ["mkdir", "cp", "chmod"];
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		return [
			["mkdir", "-p", bundleBinDir],
			["cp", supervisorStageSource, supervisorPath],
			["chmod", "+x", supervisorPath],
		];
	}
}

version (unittest) import fluent.asserts;

@safe unittest
{
	auto tool = new SupervisorTool;
	tool.name.should.equal("supervisor");
	tool.requires.should.equal(["mkdir", "cp", "chmod"]);

	InitContext ctx;
	auto steps = tool.steps(ctx);
	steps.length.should.equal(3);
	steps[0].should.equal(["mkdir", "-p", "/lore/bin"]);
	steps[1].should.equal(["cp", "/usr/local/lib/ai-agent/ai-agent-supervisor", "/lore/bin/ai-agent-supervisor"]);
	steps[2].should.equal(["chmod", "+x", "/lore/bin/ai-agent-supervisor"]);

	// Staged on every run, whatever the model.
	ctx.model = "gpt-5-codex";
	tool.steps(ctx).length.should.equal(3);
}
