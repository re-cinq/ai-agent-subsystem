module agentcore.output.event;

import vibe.data.json : Json, parseJsonString;
import std.exception : enforce;
import std.process : environment;

import agentcore.core.env : envAgentName, envPodName, envPodNamespace, envStationName,
	envTaskId;

version (unittest) import fluent.asserts;

/// Identifying metadata for a run, stamped onto every emitted event so a
/// downstream workflow / assembly line can correlate it back to its agent + pod.
struct EventSource
{
	string agent;
	string station;
	string task;
	string pod;
	string namespace_;
}

/// The run identity the controller injects, read from the environment and stamped
/// onto every emitted event so it correlates with the run's other events downstream.
EventSource sourceFromEnv()
{
	EventSource s;
	s.agent = environment.get(envAgentName, "");
	s.station = environment.get(envStationName, "");
	s.task = environment.get(envTaskId, "");
	s.pod = environment.get(envPodName, "");
	s.namespace_ = environment.get(envPodNamespace, "");
	return s;
}

/// True when `rawLine` is already a `{"source": ..., "event": ...}` envelope.
bool isWrappedLine(string rawLine) nothrow
{
	try
	{
		const parsed = parseJsonString(rawLine);
		if (parsed.type != Json.Type.object)
			return false;
		return ("source" in parsed) !is null && ("event" in parsed) !is null;
	}
	catch (Exception)
		return false;
}

/// Wrap one agent output line in an envelope carrying the run's source ids:
/// `{"source": {...}, "event": <parsed line, or the raw string>}`. Empty ids are
/// omitted. Enforce-throws when `rawLine` is already a wrapped envelope — the
/// attribution layer is applied exactly once, never nested. Any other failure
/// returns `rawLine` unchanged.
string wrapEvent(in EventSource src, string rawLine)
{
	enforce(!isWrappedLine(rawLine),
		"refusing to wrap an already-wrapped agent output line — the envelope is applied exactly once");
	try
	{
		Json[string] source;
		if (src.agent.length)
			source["agent"] = Json(src.agent);
		if (src.station.length)
			source["station"] = Json(src.station);
		if (src.task.length)
			source["task"] = Json(src.task);
		if (src.pod.length)
			source["pod"] = Json(src.pod);
		if (src.namespace_.length)
			source["namespace"] = Json(src.namespace_);

		Json event;
		try
			event = parseJsonString(rawLine);
		catch (Exception)
			event = Json(rawLine);

		Json[string] envelope;
		envelope["source"] = Json(source);
		envelope["event"] = event;
		return Json(envelope).toString();
	}
	catch (Exception)
		return rawLine;
}

unittest
{
	EventSource src = {agent: "run-1", station: "st", pod: "pod-abc"};
	const e = wrapEvent(src, `{"i":0}`);
	e.should.contain(`"agent":"run-1"`);
	e.should.contain(`"pod":"pod-abc"`);
	e.should.contain(`"station":"st"`);
	e.should.contain(`"i":0`); // original payload nested under "event"
	e.should.not.contain(`"task"`); // empty ids are omitted

	// a non-JSON line is wrapped as a string
	wrapEvent(src, "oops").should.contain(`"event":"oops"`);

	// no ids -> payload still preserved
	EventSource none;
	wrapEvent(none, `{"i":1}`).should.contain(`"i":1`);
}

unittest
{
	// Wrapping an already-wrapped line enforce-throws — never nests.
	EventSource src = {agent: "run-1"};
	const wrapped = wrapEvent(src, `{"type":"result","is_error":false,"result":"done"}`);
	isWrappedLine(wrapped).should.equal(true);
	({ wrapEvent(src, wrapped); }).should.throwException!Exception
		.withMessage.equal(
			"refusing to wrap an already-wrapped agent output line — the envelope is applied exactly once");

	// The detector accepts only the envelope shape, not arbitrary JSON or text.
	isWrappedLine(`{"type":"result"}`).should.equal(false);
	isWrappedLine(`{"source":"only"}`).should.equal(false);
	isWrappedLine("plain text").should.equal(false);
}
