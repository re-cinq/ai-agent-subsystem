module agentcore.tools.tool;

import agentcore.output.retry : RetryPolicy;
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

/// A tool the runner may run whole again after a failed step: each of its step
/// sequences re-establishes its own preconditions, so a second run is the first
/// run, a moment later. The git tool wears this because GitHub sometimes refuses
/// a clone moments after the broker minted its token — `remote: Repository not
/// found.` on a repo that exists — and the only cure is the same clone a few
/// seconds older.
interface Retryable
{
	/// How many whole runs the tool gets and how long the runner sleeps between them.
	RetryPolicy retryPolicy() const @safe;
}
