module agentcore.output;

import std.json : parseJSON;

import agentcore.crds.enums : SinkType;

/// A resolved output sink: where the supervisor sends each emitted line. The
/// controller builds these from the recipe's `output.sinks` and injects them as
/// JSON (see `parseSinks`).
struct SinkSpec
{
	SinkType type;
	string url; /// for `http`
	string path; /// for `file`
}

/// Parse a JSON array of sinks (the value of the `AGENT_SINKS` env var) into
/// `SinkSpec`s. A malformed document yields an empty list rather than throwing.
SinkSpec[] parseSinks(string json)
{
	if (json.length == 0)
		return null;

	SinkSpec[] sinks;
	try
	{
		foreach (entry; parseJSON(json).array)
		{
			auto obj = entry.object;
			auto type = "type" in obj;
			if (type is null)
				continue;
			SinkSpec s;
			s.type = toSinkType((*type).str);
			if (auto url = "url" in obj)
				s.url = (*url).str;
			if (auto path = "path" in obj)
				s.path = (*path).str;
			sinks ~= s;
		}
	}
	catch (Exception)
		return null;
	return sinks;
}

private SinkType toSinkType(string s)
{
	switch (s)
	{
	case "http":
		return SinkType.http;
	case "file":
		return SinkType.file;
	default:
		return SinkType.stdout;
	}
}

unittest
{
	auto sinks = parseSinks(`[{"type":"http","url":"http://collector/x"},{"type":"file","path":"/tmp/out"}]`);
	assert(sinks.length == 2);
	assert(sinks[0].type == SinkType.http && sinks[0].url == "http://collector/x");
	assert(sinks[1].type == SinkType.file && sinks[1].path == "/tmp/out");

	assert(parseSinks("") is null);
	assert(parseSinks("not json") is null);
	assert(parseSinks("[]").length == 0);
	// entries without a type are skipped
	assert(parseSinks(`[{"url":"http://x"}]`).length == 0);
}
