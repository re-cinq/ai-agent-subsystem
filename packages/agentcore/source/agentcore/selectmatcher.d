module agentcore.selectmatcher;

import std.algorithm.searching : canFind;
import std.json : JSONType, JSONValue, parseJSON;

import agentcore.crds.enums : SelectEvent, SelectRole;
import agentcore.crds.output_selector : OutputSelector;

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
		event = classify(provider, parseJSON(payload));
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
/// injected as JSON) back into selectors. Mirrors `parseSinks`: a malformed
/// document yields an empty list rather than throwing.
OutputSelector[] parseSelectors(string json)
{
	if (json.length == 0)
		return null;

	OutputSelector[] selectors;
	try
	{
		foreach (entry; parseJSON(json).array)
		{
			auto object = entry.object;
			auto event = "event" in object;
			if (event is null)
				continue;
			OutputSelector selector;
			selector.event = toSelectEvent((*event).str);
			if (auto tool = "tool" in object)
				selector.tool = (*tool).str;
			if (auto contains = "contains" in object)
				selector.contains = (*contains).str;
			selectors ~= selector;
		}
	}
	catch (Exception)
		return null;
	return selectors;
}

private SelectEvent toSelectEvent(string name)
{
	switch (name)
	{
	case "tool_call":
		return SelectEvent.toolCall;
	case "tool_result":
		return SelectEvent.toolResult;
	case "message":
		return SelectEvent.message;
	case "usage":
		return SelectEvent.usage;
	default:
		return SelectEvent.result;
	}
}

/// Normalize one provider event to the `SelectEvent` vocabulary. Claude's
/// `stream-json` is mapped from real event shapes; Codex's `--json` is best-effort
/// off its `type` field. (Role filtering is intentionally omitted — the CRD's
/// `SelectRole` has no "unset" value, so it cannot be distinguished from
/// `assistant`.)
Classified classify(string provider, JSONValue event)
{
	if (event.type != JSONType.object)
		return Classified.init;
	return provider == "codex" ? classifyCodex(event) : classifyClaude(event);
}

private Classified classifyClaude(JSONValue event)
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
private Classified fromContent(JSONValue[] content, SelectEvent fallback)
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

private Classified classifyCodex(JSONValue event)
{
	const type = strAt(event, "type");
	if (canFind(type, "result") || canFind(type, "complete"))
		return Classified(true, SelectEvent.result, "", strAt(event, "text"));
	if (canFind(type, "tool") || canFind(type, "command") || canFind(type, "function"))
		return Classified(true, SelectEvent.toolCall, strAt(event, "name"));
	if (canFind(type, "token") || canFind(type, "usage"))
		return Classified(true, SelectEvent.usage);
	if (canFind(type, "message"))
		return Classified(true, SelectEvent.message, "", strAt(event, "text"));
	return Classified.init;
}

private JSONValue[] messageContent(JSONValue event)
{
	if (auto message = "message" in event.object)
		if (message.type == JSONType.object)
			if (auto content = "content" in message.object)
				if (content.type == JSONType.array)
					return content.array;
	return null;
}

private string strAt(JSONValue object, string key)
{
	if (object.type != JSONType.object)
		return "";
	if (auto value = key in object.object)
		return value.type == JSONType.string ? value.str : "";
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
