module agentcore.event;

import std.json : parseJSON, JSONValue;

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

/// Wrap one agent output line in an envelope carrying the run's source ids:
/// `{"source": {...}, "event": <parsed line, or the raw string>}`. Empty ids are
/// omitted. Never throws — on any failure it returns `rawLine` unchanged.
string wrapEvent(in EventSource src, string rawLine) nothrow
{
	try
	{
		JSONValue[string] source;
		if (src.agent.length)
			source["agent"] = JSONValue(src.agent);
		if (src.station.length)
			source["station"] = JSONValue(src.station);
		if (src.task.length)
			source["task"] = JSONValue(src.task);
		if (src.pod.length)
			source["pod"] = JSONValue(src.pod);
		if (src.namespace_.length)
			source["namespace"] = JSONValue(src.namespace_);

		JSONValue event;
		try
			event = parseJSON(rawLine);
		catch (Exception)
			event = JSONValue(rawLine);

		JSONValue[string] envelope;
		envelope["source"] = JSONValue(source);
		envelope["event"] = event;
		return JSONValue(envelope).toString();
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
