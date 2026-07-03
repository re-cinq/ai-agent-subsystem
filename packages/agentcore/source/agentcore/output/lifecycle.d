module agentcore.output.lifecycle;

import vibe.data.json : Json;
import std.typecons : Nullable;

version (unittest) import fluent.asserts;

/// Discriminator stamped on every lifecycle event so a consumer can tell a typed
/// lifecycle notification apart from raw agent output (which carries its own `type`).
enum lifecycleKind = "lifecycle";

/// Which container is reporting: the init container or the agent supervisor.
enum Phase : string
{
	init_ = "init",
	agent = "agent",
}

/// Where a phase is in its lifecycle.
enum Status : string
{
	started = "started",
	installing = "installing",
	running = "running",
	succeeded = "succeeded",
	failed = "failed",
}

/// A typed lifecycle notification raised by both the init container and the
/// supervisor, serialized as the inner `event` payload of the shared envelope so the
/// two containers' streams look identical to a downstream hook.
struct LifecycleEvent
{
	Phase phase;
	Status status;
	string tool; /// optional: the tool or package-manager name involved
	string reason; /// optional: a short failure slug ("home", "spawn", …)
	Nullable!int exitCode; /// optional: a process exit code
}

/// The compact JSON line for the envelope's `event`: tags `"kind":"lifecycle"` and
/// omits empty optionals. Never throws — it is emitted from nothrow paths.
string toJson(in LifecycleEvent e) nothrow
{
	try
	{
		Json[string] o;
		o["kind"] = Json(lifecycleKind);
		o["phase"] = Json(cast(string) e.phase);
		o["status"] = Json(cast(string) e.status);
		if (e.tool.length)
			o["tool"] = Json(e.tool);
		if (e.reason.length)
			o["reason"] = Json(e.reason);
		if (!e.exitCode.isNull)
			o["exitCode"] = Json(e.exitCode.get);
		return Json(o).toString();
	}
	catch (Exception)
		return `{"kind":"lifecycle","status":"failed"}`;
}

unittest
{
	const e = LifecycleEvent(Phase.init_, Status.started).toJson;
	e.should.contain(`"kind":"lifecycle"`);
	e.should.contain(`"phase":"init"`);
	e.should.contain(`"status":"started"`);
	// empty optionals are omitted
	e.should.not.contain(`"tool"`);
	e.should.not.contain(`"reason"`);
	e.should.not.contain(`"exitCode"`);
}

unittest
{
	// tool carries through for installing / running
	LifecycleEvent(Phase.init_, Status.installing, "apt").toJson
		.should.contain(`"tool":"apt"`);
}

unittest
{
	// a failure reason carries through, and the agent phase serializes
	LifecycleEvent ev = {phase: Phase.agent, status: Status.failed};
	ev.reason = "not-found";
	const json = ev.toJson;
	json.should.contain(`"phase":"agent"`);
	json.should.contain(`"reason":"not-found"`);
}

unittest
{
	// exitCode 0 is present (not treated as empty); a non-zero code carries through
	LifecycleEvent ok = {phase: Phase.agent, status: Status.succeeded};
	ok.exitCode = 0;
	ok.toJson.should.contain(`"exitCode":0`);

	LifecycleEvent crash = {phase: Phase.agent, status: Status.failed};
	crash.exitCode = 42;
	crash.toJson.should.contain(`"exitCode":42`);
}
