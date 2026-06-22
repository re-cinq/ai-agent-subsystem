module agentcore.tools.tool;

import agentcore.tools.initcontext : InitContext;

/// A pluggable environment-provisioning step run in the init container — cloning a
/// repo, installing a CLI, and so on. A tool reports the executables it needs and
/// the argv steps to run; the initializer installs any missing prerequisites, then
/// runs the steps in order. New tools are added by implementing this interface —
/// nothing else in the init changes.
interface Tool
{
	/// Identifier for logs and notifications (e.g. "git", "claude").
	string name() const @safe;

	/// Executables this tool needs on `PATH` when it is active (has steps).
	string[] requires() const @safe;

	/// The argv steps that provision `ctx`, in order. Empty when this run does not
	/// need the tool (no git ref, or a model that isn't Claude). The runner runs
	/// each step and fails the init container on the first non-zero exit.
	string[][] steps(in InitContext ctx) const @safe;
}
