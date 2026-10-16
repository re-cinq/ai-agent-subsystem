module agentcore.output.session;

import std.algorithm.iteration : splitter;
import std.array : array;
import std.range : retro;

import vibe.data.json : Json, parseJsonString;

version (unittest) import fluent.asserts;

/// Discriminator of the event carrying the harness session id, so a caller can pass
/// it back as `spec.resumeSession` to continue the conversation.
enum sessionKind = "session";

/// The harness session id announced by `payload`, or "" when the line announces none.
/// Claude's `stream-json` opens with `{"type":"system","subtype":"init","session_id":…}`,
/// Codex's `exec --json` with `{"type":"thread.started","thread_id":…}` and Gemini's
/// `stream-json` with `{"type":"init","session_id":…}`. Never throws — it runs on the
/// supervisor's nothrow output path.
string sessionIdFor(string provider, string payload) nothrow
{
	try
	{
		auto event = parseJsonString(payload);
		if (event.type != Json.Type.object)
			return "";
		switch (provider)
		{
		case "codex":
			return strAt(event, "type") == "thread.started" ? strAt(event, "thread_id") : "";
		case "gemini":
			return strAt(event, "type") == "init" ? strAt(event, "session_id") : "";
		default:
			return strAt(event, "type") == "system" && strAt(event, "subtype") == "init"
				? strAt(event, "session_id") : "";
		}
	}
	catch (Exception)
		return "";
}

/// The `{"kind":"session","id":…}` event line the supervisor raises for `id`.
string sessionEvent(string id) nothrow
{
	try
		return `{"kind":"` ~ sessionKind ~ `","id":` ~ Json(id).toString() ~ "}";
	catch (Exception)
		return `{"kind":"session"}`;
}

/// The id of the last session event in a run's pod `log`, or "" when it holds none.
/// Lines are the supervisor's `{"source":…,"event":…}` envelopes; anything else —
/// stderr diagnostics, a truncation marker — is skipped.
string lastSessionId(string log)
{
	foreach (line; log.splitter('\n').array.retro)
	{
		const id = sessionIdOfLine(line);
		if (id.length)
			return id;
	}
	return "";
}

private string sessionIdOfLine(string line) nothrow
{
	try
	{
		auto parsed = parseJsonString(line);
		if (parsed.type != Json.Type.object)
			return "";
		auto event = "event" in parsed ? parsed["event"] : parsed;
		return strAt(event, "kind") == sessionKind ? strAt(event, "id") : "";
	}
	catch (Exception)
		return "";
}

private string strAt(Json object, string key)
{
	if (object.type != Json.Type.object)
		return "";
	if (auto value = key in object)
		return value.type == Json.Type.string ? value.get!string : "";
	return "";
}

unittest // claude init, codex thread.started and gemini init each carry the session id
{
	[sessionIdFor("claude", `{"type":"system","subtype":"init","session_id":"c-1"}`),
		sessionIdFor("codex", `{"type":"thread.started","thread_id":"t-1"}`),
		sessionIdFor("gemini", `{"type":"init","session_id":"g-1","model":"gemini-3.1-flash-lite"}`)]
		.should.equal(["c-1", "t-1", "g-1"]);
}

unittest // lines other than the vendor's opening event carry no session id
{
	[sessionIdFor("claude", `{"type":"result","session_id":"c-1"}`),
		sessionIdFor("claude", `{"type":"init","session_id":"g-1"}`),
		sessionIdFor("codex", `{"type":"turn.completed"}`),
		sessionIdFor("gemini", `{"type":"system","subtype":"init","session_id":"c-1"}`),
		sessionIdFor("claude", "not json"),
		sessionIdFor("claude", `"a string"`)]
		.should.equal(["", "", "", "", "", ""]);
}

unittest // the session event round-trips through the pod log scanner
{
	sessionEvent(`a"b`).should.equal(`{"kind":"session","id":"a\"b"}`);
	lastSessionId(sessionEvent(`a"b`)).should.equal(`a"b`);
	lastSessionId(sessionEvent("abc")).should.equal("abc");
}

unittest // the last wrapped session event in a pod log wins over earlier ones and noise
{
	const log = `{"source":{"agent":"a"},"event":{"kind":"session","id":"first"}}` ~ "\n"
		~ "[agent] some stderr\n"
		~ `{"source":{"agent":"a"},"event":{"kind":"session","id":"second"}}` ~ "\n"
		~ `{"source":{"agent":"a"},"event":{"kind":"lifecycle","status":"succeeded"}}` ~ "\n";
	lastSessionId(log).should.equal("second");
}

unittest // a pod log without session events yields no id
{
	lastSessionId(`{"source":{},"event":{"type":"result"}}` ~ "\nplain\n").should.equal("");
	lastSessionId("").should.equal("");
}
