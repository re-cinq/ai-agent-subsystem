module agentcore.delivery.outbox;

import std.algorithm.iteration : splitter;
import std.array : array;
import std.conv : to;
import std.range : retro;

import vibe.data.json : Json, parseJsonString;

import agentcore.crds.schema : optional;
import agentcore.crds.serialization : fromJson, toJson;

/// The git bundle of the work branch the supervisor leaves in the outbox.
enum bundleName = "run.bundle";

/// The marker the supervisor writes last, once the outbox holds all it will hold. The
/// courier waits for it, so a half-written bundle is never pushed.
enum outcomeName = "outcome.json";

/// What the outbox holds: `ready` with a bundle to deliver, `empty` when the run left
/// nothing to deliver, `broken` when it should have and could not.
enum OutboxState : string
{
	broken = "broken",
	empty = "empty",
	ready = "ready",
}

/// What the supervisor left for the courier, and why when there is nothing to push.
struct OutboxOutcome
{
	@optional OutboxState state;
	@optional string reason;
}

/// The outcome of a run that exited with `exitCode`, whose clone's HEAD moved from
/// `startHead` to `endHead`: only a successful run that committed something delivers.
OutboxOutcome outboxOutcome(int exitCode, string startHead, string endHead) @safe pure
{
	if (exitCode != 0)
		return OutboxOutcome(OutboxState.empty, "agent exited " ~ exitCode.to!string);
	if (endHead.length == 0)
		return OutboxOutcome(OutboxState.empty, "no commit to deliver");
	if (endHead == startHead)
		return OutboxOutcome(OutboxState.empty, "no new commits");
	return OutboxOutcome(OutboxState.ready);
}

/// The marker file's contents for `outcome`.
string outcomeJson(const OutboxOutcome outcome)
{
	return toJson(outcome).toString();
}

/// The outcome in the marker file's `contents`. The outbox is writable by the agent, so
/// anything unreadable is broken; an unknown state degrades to `broken` too.
OutboxOutcome parseOutcome(string contents)
{
	try
		return fromJson!OutboxOutcome(parseJsonString(contents));
	catch (Exception)
		return OutboxOutcome(OutboxState.broken, "unreadable outbox outcome");
}

/// Discriminator of the event the courier raises once the delivery is settled.
enum deliveryKind = "delivery";

/// How a delivery ended: `opened` with the pull request's url, `skipped` when the run
/// left nothing to deliver, `failed` with the reason; `none` before the courier reports.
enum DeliveryStatus : string
{
	none = "",
	opened = "opened",
	skipped = "skipped",
	failed = "failed",
}

struct DeliveryReport
{
	DeliveryStatus status;
	string url;
	string reason;
}

/// The `{"kind":"delivery",…}` event line the courier raises for `report`.
string deliveryEvent(const DeliveryReport report)
{
	auto event = Json(["kind": Json(deliveryKind), "status": Json(cast(string) report.status)]);
	if (report.url.length)
		event["url"] = report.url;
	if (report.reason.length)
		event["reason"] = report.reason;
	return event.toString();
}

/// The last delivery event in the courier's `log`, or an empty report when it raised
/// none. Lines may be bare events or `{"source":…,"event":…}` envelopes; anything else
/// is skipped.
DeliveryReport lastDelivery(string log)
{
	foreach (line; log.splitter('\n').array.retro)
	{
		const report = deliveryOfLine(line);
		if (report.status != DeliveryStatus.none)
			return report;
	}
	return DeliveryReport.init;
}

private DeliveryReport deliveryOfLine(string line) nothrow
{
	try
	{
		auto parsed = parseJsonString(line);
		auto event = "event" in parsed ? parsed["event"] : parsed;
		if (event["kind"].opt!string("") != deliveryKind)
			return DeliveryReport.init;
		return DeliveryReport(event["status"].opt!string("").to!DeliveryStatus,
			event["url"].opt!string(""), event["reason"].opt!string(""));
	}
	catch (Exception)
		return DeliveryReport.init;
}

version (unittest) import fluent.asserts;

@safe unittest // only a successful run whose HEAD moved delivers
{
	[outboxOutcome(0, "a1", "b2"), outboxOutcome(3, "a1", "b2"), outboxOutcome(0, "a1", "a1"),
		outboxOutcome(0, "a1", "")].should.equal([
		OutboxOutcome(OutboxState.ready),
		OutboxOutcome(OutboxState.empty, "agent exited 3"),
		OutboxOutcome(OutboxState.empty, "no new commits"),
		OutboxOutcome(OutboxState.empty, "no commit to deliver"),
	]);
}

unittest // an outcome round-trips through the marker file, and garbage or an unknown state is broken
{
	[
		parseOutcome(outcomeJson(OutboxOutcome(OutboxState.ready))),
		parseOutcome(outcomeJson(OutboxOutcome(OutboxState.empty, "no new commits"))),
		parseOutcome("not json"),
		parseOutcome(`{"state":"shipped"}`),
	].should.equal([
		OutboxOutcome(OutboxState.ready),
		OutboxOutcome(OutboxState.empty, "no new commits"),
		OutboxOutcome(OutboxState.broken, "unreadable outbox outcome"),
		OutboxOutcome(OutboxState.broken),
	]);
}

unittest // a delivery event carries its status with the url or the reason through the log scanner
{
	const opened = DeliveryReport(DeliveryStatus.opened, "https://github.com/o/app/pull/7");
	const skipped = DeliveryReport(DeliveryStatus.skipped, "", "no new commits");

	[lastDelivery(deliveryEvent(opened)), lastDelivery(deliveryEvent(skipped))].should.equal([opened, skipped]);
	parseJsonString(deliveryEvent(skipped)).should.equal(
		parseJsonString(`{"kind":"delivery","status":"skipped","reason":"no new commits"}`));
}

unittest // the last delivery event in a courier log wins, bare or wrapped, over noise
{
	const log = `{"source":{"agent":"a"},"event":{"kind":"delivery","status":"failed","reason":"x"}}` ~ "\n"
		~ "[courier] some stderr\n"
		~ `{"kind":"delivery","status":"opened","url":"https://github.com/o/app/pull/7"}` ~ "\n"
		~ `{"kind":"lifecycle","status":"succeeded"}` ~ "\n";

	lastDelivery(log).should.equal(DeliveryReport(DeliveryStatus.opened, "https://github.com/o/app/pull/7"));
}

unittest // a log without delivery events, or with an unknown status, reports nothing
{
	[lastDelivery(""), lastDelivery("plain\n" ~ `{"kind":"delivery","status":"teleported"}`)]
		.should.equal([DeliveryReport.init, DeliveryReport.init]);
}
