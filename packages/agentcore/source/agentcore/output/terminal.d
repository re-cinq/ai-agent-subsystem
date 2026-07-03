module agentcore.output.terminal;

import vibe.data.json : Json, parseJsonString;

version (unittest) import fluent.asserts;

/// The agent's terminal signal, derived from a single output line. `reached` is
/// true when the line is the provider's final event; `ok` is whether the run
/// finished successfully. The supervisor uses this so it can exit on the agent's
/// own "work done" signal rather than blocking on a process that may never exit
/// (some agent CLIs emit their result then leave a worker holding the process
/// open — every such run would otherwise burn the Job deadline and report Failed).
struct Terminal
{
	bool reached;
	bool ok;
}

/// Detect the agent's terminal event in `payload`. Claude's `stream-json` ends with
/// a single `{"type":"result","is_error":bool,...}`; Codex's `exec --json` ends its
/// turn with `{"type":"turn.completed",...}` (it has no error field, so a completed
/// turn is treated as success). Anything else is not terminal. Never throws — it
/// runs on the supervisor's nothrow output path, so a malformed line is just "not
/// terminal".
Terminal terminalFor(string provider, string payload) nothrow
{
	try
	{
		auto event = parseJsonString(payload);
		if (event.type != Json.Type.object)
			return Terminal.init;
		return provider == "codex" ? codexTerminal(event) : claudeTerminal(event);
	}
	catch (Exception)
		return Terminal.init;
}

private Terminal claudeTerminal(Json event)
{
	if (strAt(event, "type") != "result")
		return Terminal.init;
	return Terminal(true, !boolAt(event, "is_error"));
}

private Terminal codexTerminal(Json event)
{
	if (strAt(event, "type") != "turn.completed")
		return Terminal.init;
	return Terminal(true, true);
}

private string strAt(Json object, string key)
{
	if (object.type != Json.Type.object)
		return "";
	if (auto value = key in object)
		return value.type == Json.Type.string ? value.get!string : "";
	return "";
}

private bool boolAt(Json object, string key)
{
	if (object.type != Json.Type.object)
		return false;
	if (auto value = key in object)
		return value.type == Json.Type.bool_ && value.get!bool;
	return false;
}

unittest
{
	// Claude: a successful result is terminal and ok.
	terminalFor("claude", `{"type":"result","subtype":"success","is_error":false}`)
		.should.equal(Terminal(true, true));
	// Claude: a result with is_error is terminal but not ok.
	terminalFor("claude", `{"type":"result","subtype":"error_during_execution","is_error":true}`)
		.should.equal(Terminal(true, false));
	// Claude: a missing is_error defaults to success.
	terminalFor("claude", `{"type":"result"}`).should.equal(Terminal(true, true));
}

unittest
{
	// Claude: non-result events are not terminal.
	terminalFor("claude", `{"type":"assistant","message":{"content":[]}}`)
		.should.equal(Terminal(false, false));
	terminalFor("claude", `{"type":"system","subtype":"init"}`).should.equal(Terminal(false, false));
}

unittest
{
	// Codex: a completed turn is the terminal event (no distinct result event).
	terminalFor("codex", `{"type":"turn.completed","usage":{"input_tokens":1}}`)
		.should.equal(Terminal(true, true));
	// Codex: an item completion is not terminal.
	terminalFor("codex",
		`{"type":"item.completed","item":{"type":"agent_message","text":"done"}}`)
		.should.equal(Terminal(false, false));
}

unittest
{
	// A malformed or non-object line is never terminal.
	terminalFor("claude", "not json").should.equal(Terminal(false, false));
	terminalFor("claude", `"a string"`).should.equal(Terminal(false, false));
	terminalFor("claude", "").should.equal(Terminal(false, false));
}
