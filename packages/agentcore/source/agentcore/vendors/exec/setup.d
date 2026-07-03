module agentcore.vendors.exec.setup;

import agentcore.vendors.base.setup : AgentSetup;

/// The exec vendor installs nothing: the station image already contains the
/// command named in `tool_config.command` (that is the whole point of a custom
/// station image), so the init container has no CLI to fetch.
final class ExecSetup : AgentSetup
{
	override string name() const @safe
	{
		return "exec";
	}

	override string[] requires() const @safe
	{
		return [];
	}

	override string[][] installSteps() const @safe
	{
		return [];
	}
}

version (unittest) import fluent.asserts;

@safe unittest
{
	auto exec = new ExecSetup;
	exec.name.should.equal("exec");
	exec.requires.length.should.equal(0);
	exec.installSteps.length.should.equal(0);
}
