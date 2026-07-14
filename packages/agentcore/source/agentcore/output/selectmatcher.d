module agentcore.output.selectmatcher;

import std.algorithm.searching : canFind;
import vibe.data.json : Json, parseJsonString;

import agentcore.crds.enums : SelectEvent, SelectRole;
import agentcore.crds.output_selector : OutputSelector;
import agentcore.crds.serialization : fromJson, isEnumWireValue;
import agentcore.core.log : logError;

/// A provider event normalized to the recipe's vocabulary: its `SelectEvent` type
/// plus the tool name and text needed to evaluate a selector's `tool`/`contains`.
/// `known` is false when the event doesn't map to any `SelectEvent` (lifecycle
/// noise, token accounting we ignore, unrecognised shapes).
struct Classified
{
	bool known;
	SelectEvent type;
	string tool;
	string text;
}

/// Whether an agent event should be delivered to the recipe's sinks. Empty
/// `selectors` ⇒ everything passes (the default). Otherwise selectors are an
/// allowlist: an event passes iff it matches one (by `event`, and the optional
/// `tool`/`contains` narrowing). Events that don't parse or don't classify are
/// dropped from sinks — but the supervisor always echoes them to stdout, so the
/// pod log / `status.output` stays complete regardless.
bool selected(const OutputSelector[] selectors, string provider, string payload) nothrow
{
	if (selectors.length == 0)
		return true;

	Classified event;
	try
		event = classify(provider, parseJsonString(payload));
	catch (Exception)
		return false;

	if (!event.known)
		return false;

	foreach (selector; selectors)
	{
		if (selector.event != event.type)
			continue;
		if (selector.tool.length && selector.tool != event.tool)
			continue;
		if (selector.contains.length && !event.text.canFind(selector.contains))
			continue;
		return true;
	}
	return false;
}

/// Parse the `AGENT_SELECT` env var (the recipe's `output.select` the controller
/// injected as JSON) back into the `OutputSelector` CRD structs — the same type the
/// controller serialized, so no field is dropped here. An entry missing its `event` is
/// skipped (the controller never emits one); an entry whose `event` is not a known
/// `SelectEvent` wire value is skipped too, so a typo can't silently degrade to the
/// enum's first member (tool_call) and start matching tool calls; a malformed document
/// yields an empty list rather than throwing.
OutputSelector[] parseSelectors(string json)
{
	if (json.length == 0)
		return null;

	OutputSelector[] selectors;
	try
	{
		foreach (entry; parseJsonString(json).get!(Json[]))
		{
			auto event = "event" in entry;
			if (event is null || event.type != Json.Type.string)
				continue;
			if (!isEnumWireValue!SelectEvent(event.get!string))
			{
				// An unknown event can't map to a SelectEvent, so the entry is dropped
				// rather than silently degrading to the enum's first member (tool_call).
				// The CRD enum rejects this at admission so it should be unreachable; log
				// it so a selector that slipped past validation is diagnosable, and note
				// the drop is fail-open (if it was the only selector, everything passes) —
				// stdout still carries the full stream regardless.
				logError("[selectmatcher] dropping output.select entry with unknown event '"
						~ event.get!string ~ "'");
				continue;
			}
			selectors ~= fromJson!OutputSelector(entry);
		}
	}
	catch (Exception)
		return null;
	return selectors;
}

/// Normalize one provider event to the `SelectEvent` vocabulary. Both mappings are
/// grounded in real output: Claude's `stream-json` and Codex's `exec --json`. (Role
/// filtering is intentionally omitted — the CRD's `SelectRole` has no "unset" value,
/// so it cannot be distinguished from `assistant`.)
Classified classify(string provider, Json event)
{
	if (event.type != Json.Type.object)
		return Classified.init;
	return provider == "codex" ? classifyCodex(event) : classifyClaude(event);
}

private Classified classifyClaude(Json event)
{
	const type = strAt(event, "type");
	switch (type)
	{
	case "result":
		return Classified(true, SelectEvent.result, "", strAt(event, "result"));
	case "assistant":
		return fromContent(messageContent(event), SelectEvent.message);
	case "user":
		return fromContent(messageContent(event), SelectEvent.message);
	case "system":
		return canFind(strAt(event, "subtype"), "token")
			? Classified(true, SelectEvent.usage) : Classified.init;
	default:
		return Classified.init;
	}
}

/// Classify a Claude assistant/user message from its content blocks: a `tool_use`
/// block is a tool_call, a `tool_result` block is a tool_result, otherwise the
/// joined text is a message.
private Classified fromContent(Json[] content, SelectEvent fallback)
{
	string text;
	foreach (block; content)
	{
		const blockType = strAt(block, "type");
		if (blockType == "tool_use")
			return Classified(true, SelectEvent.toolCall, strAt(block, "name"));
		if (blockType == "tool_result")
			return Classified(true, SelectEvent.toolResult, "", strAt(block, "content"));
		if (blockType == "text")
			text ~= strAt(block, "text");
	}
	return Classified(true, fallback, "", text);
}

/// Normalize a Codex `exec --json` event. Codex streams thread/turn lifecycle plus
/// `item.completed` events whose nested `item.type` names what was produced, and token
/// usage on `turn.completed`. Codex has no distinct result event — the final answer is
/// an `agent_message` (select `message`). Lifecycle, in-progress (`item.started`/
/// `item.updated`) and internal `reasoning` events don't map; they're dropped from
/// sinks while stdout keeps the full stream.
private Classified classifyCodex(Json event)
{
	const type = strAt(event, "type");
	if (type == "turn.completed")
		return Classified(true, SelectEvent.usage);
	if (type != "item.completed")
		return Classified.init;
	return classifyCodexItem(childObject(event, "item"));
}

/// Classify a completed Codex item by its `item.type`: the assistant's answer
/// (`agent_message`) is a message; a shell `command_execution`, an `mcp_tool_call`, a
/// `file_change` or a `web_search` is a tool_call (carrying the command text or the
/// tool name for narrowing). Reasoning and anything unrecognised stay unclassified.
private Classified classifyCodexItem(Json item)
{
	switch (strAt(item, "type"))
	{
	case "agent_message":
		return Classified(true, SelectEvent.message, "", strAt(item, "text"));
	case "command_execution":
		return Classified(true, SelectEvent.toolCall, "", strAt(item, "command"));
	case "mcp_tool_call":
		return Classified(true, SelectEvent.toolCall, strAt(item, "tool"));
	case "file_change":
	case "web_search":
		return Classified(true, SelectEvent.toolCall);
	default:
		return Classified.init;
	}
}

private Json childObject(Json event, string key)
{
	if (event.type == Json.Type.object)
		if (auto value = key in event)
			if (value.type == Json.Type.object)
				return *value;
	return Json.init;
}

private Json[] messageContent(Json event)
{
	if (auto message = "message" in event)
		if (message.type == Json.Type.object)
			if (auto content = "content" in *message)
				if (content.type == Json.Type.array)
					return content.get!(Json[]);
	return null;
}

private string strAt(Json object, string key)
{
	if (object.type != Json.Type.object)
		return "";
	if (auto value = key in object)
		return value.type == Json.Type.string ? value.get!string : "";
	return "";
}

version (unittest) import fluent.asserts;

unittest
{
	// No selectors -> everything passes.
	selected(null, "claude", `{"type":"result"}`).should.equal(true);
}

unittest
{
	// #114: an unrecognized event string is dropped, not silently degraded to the enum's
	// first member (tool_call) — a typo'd selector must never start matching tool calls.
	parseSelectors(`[{"event":"reslt"}]`).length.should.equal(0);

	auto ok = parseSelectors(`[{"event":"result"}]`);
	ok.length.should.equal(1);
	ok[0].event.should.equal(SelectEvent.result);
}

unittest
{
	auto onlyResults = [OutputSelector(SelectEvent.result)];
	selected(onlyResults, "claude",
		`{"type":"result","subtype":"success","result":"# The Salt-Glass Tower"}`).should.equal(true);
	selected(onlyResults, "claude",
		`{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}`).should.equal(false);
	// A non-result, unparseable, or unclassified event is dropped from sinks.
	selected(onlyResults, "claude", `not json`).should.equal(false);
	selected(onlyResults, "claude", `{"type":"system","subtype":"thinking_tokens"}`).should.equal(false);
}

unittest
{
	// message + tool_call classification.
	auto msgs = [OutputSelector(SelectEvent.message)];
	selected(msgs, "claude",
		`{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}`).should.equal(true);

	auto toolCalls = [OutputSelector(SelectEvent.toolCall)];
	selected(toolCalls, "claude",
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}`).should.equal(true);
}

unittest
{
	// contains + tool narrowing.
	auto resultWith = [OutputSelector(SelectEvent.result, "", SelectRole.init, "Lighthouse")];
	selected(resultWith, "claude",
		`{"type":"result","result":"The Last Lighthouse"}`).should.equal(true);
	selected(resultWith, "claude",
		`{"type":"result","result":"Something else"}`).should.equal(false);

	auto readTool = [OutputSelector(SelectEvent.toolCall, "Read")];
	selected(readTool, "claude",
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}`).should.equal(true);
	selected(readTool, "claude",
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}`).should.equal(false);
}

unittest
{
	// Real `codex exec --json` shapes (issue #13): an item.completed carries the
	// produced item in `item.type`; tokens arrive on turn.completed. Codex has no
	// distinct result event — the final answer is an agent_message (-> message).
	auto messages = [OutputSelector(SelectEvent.message)];
	selected(messages, "codex",
		`{"type":"item.completed","item":{"id":"i3","type":"agent_message","text":"Done."}}`)
		.should.equal(true);

	auto toolCalls = [OutputSelector(SelectEvent.toolCall)];
	selected(toolCalls, "codex",
		`{"type":"item.completed","item":{"id":"i1","type":"command_execution",`
			~ `"command":"bash -lc ls","aggregated_output":"docs\n","exit_code":0,"status":"completed"}}`)
		.should.equal(true);

	auto usage = [OutputSelector(SelectEvent.usage)];
	selected(usage, "codex",
		`{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122}}`)
		.should.equal(true);
}

unittest
{
	// Codex tool narrowing: an mcp_tool_call exposes the tool name; a
	// command_execution exposes its command for `contains`.
	auto searchTool = [OutputSelector(SelectEvent.toolCall, "search")];
	selected(searchTool, "codex",
		`{"type":"item.completed","item":{"id":"i5","type":"mcp_tool_call",`
			~ `"server":"docs","tool":"search","status":"completed"}}`)
		.should.equal(true);
	selected(searchTool, "codex",
		`{"type":"item.completed","item":{"id":"i5","type":"mcp_tool_call",`
			~ `"server":"docs","tool":"fetch","status":"completed"}}`)
		.should.equal(false);

	auto lsCommand = [OutputSelector(SelectEvent.toolCall, "", SelectRole.init, "ls")];
	selected(lsCommand, "codex",
		`{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"bash -lc ls"}}`)
		.should.equal(true);
}

unittest
{
	// Lifecycle, in-progress (item.started/updated) and internal reasoning events do
	// not classify -> dropped from sinks (stdout still receives everything).
	auto any = [
		OutputSelector(SelectEvent.message), OutputSelector(SelectEvent.toolCall),
		OutputSelector(SelectEvent.usage), OutputSelector(SelectEvent.result),
	];
	selected(any, "codex", `{"type":"thread.started","thread_id":"t1"}`).should.equal(false);
	selected(any, "codex", `{"type":"turn.started"}`).should.equal(false);
	selected(any, "codex",
		`{"type":"item.started","item":{"id":"i1","type":"command_execution",`
			~ `"command":"bash -lc ls","status":"in_progress"}}`)
		.should.equal(false);
	selected(any, "codex",
		`{"type":"item.completed","item":{"id":"i2","type":"reasoning","text":"thinking..."}}`)
		.should.equal(false);
}
