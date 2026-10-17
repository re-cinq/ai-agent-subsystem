module outbox;

import std.file : mkdirRecurse, rename, write;
import std.process : Config, execute;
import std.string : strip;

import agentcore.core.log : logError;
import agentcore.delivery.outbox : bundleName, OutboxOutcome, outboxOutcome, OutboxState, outcomeJson,
	outcomeName;
import agentcore.delivery.plan : delivers, DeliveryPlan;

/// The commit `clone`'s HEAD points at, or "" when it has none or git cannot say.
string headOf(string clone) nothrow
{
	try
	{
		const result = execute(["git", "-C", clone, "rev-parse", "--verify", "-q", "HEAD"], null,
			Config.stderrPassThrough);
		return result.status == 0 ? result.output.strip : "";
	}
	catch (Exception)
		return "";
}

/// Leave the run's work in the outbox for the courier: the bundle of the clone's HEAD
/// when the run delivers, then the outcome marker, written last and renamed into place
/// so the courier never reads a half-written outbox. Runs once the agent has exited
/// with `exitCode`; `startHead` is the commit the clone was on before it started. A
/// no-op for a run that delivers nothing. Never throws — it runs on the terminal path.
void fillOutbox(const DeliveryPlan plan, int exitCode, string startHead) nothrow
{
	if (!delivers(plan))
		return;
	try
	{
		mkdirRecurse(plan.outbox);
		auto outcome = outboxOutcome(exitCode, startHead, headOf(plan.clone));
		if (outcome.state == OutboxState.ready && !bundled(plan))
			outcome = OutboxOutcome(OutboxState.broken, "git bundle failed");
		const marker = plan.outbox ~ "/" ~ outcomeName;
		write(marker ~ ".tmp", outcomeJson(outcome));
		rename(marker ~ ".tmp", marker);
	}
	catch (Exception e)
		logError("[outbox] " ~ e.msg);
}

/// Bundle the clone's HEAD, with all its history, so the courier can push it from a
/// repository of its own without ever running git in the agent's clone.
private bool bundled(const DeliveryPlan plan)
{
	const result = execute(["git", "-C", plan.clone, "bundle", "create", plan.outbox ~ "/" ~ bundleName, "HEAD"]);
	if (result.status != 0)
		logError("[outbox] git bundle failed: " ~ result.output);
	return result.status == 0;
}
