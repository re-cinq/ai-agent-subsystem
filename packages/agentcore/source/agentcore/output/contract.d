module agentcore.output.contract;

import std.algorithm : any, canFind, countUntil, filter, find, map, sort;
import std.exception : enforce;
import std.array : array, join, split;
import std.format : format;
import std.string : splitLines;
import agentcore.output.terminal : Terminal, terminalFor;
import vibe.data.json : Json, parseJsonString;

version (unittest) import fluent.asserts;

/// Enforce that `lines` form the complete event sequence `provider`'s CLI emits.
void enforceEventContract(string provider, const string[] lines)
{
	const found = streamRules.find!(rule => rule.provider == provider);
	enforce(found.length > 0, "no event contract for provider " ~ provider);
	const rule = found[0];
	const events = lines.map!parseJsonString.array;
	enforce(events.length > 0 && consumedEvent(events[0]) == rule.first,
		provider ~ " stream must start with " ~ rule.first);
	const terminalName = rule.terminals.join(" or ");
	const terminalIndex = events.countUntil!(event => rule.terminals.canFind(consumedEvent(event)));
	enforce(terminalIndex >= 0, provider ~ " stream is missing its " ~ terminalName ~ " line");
	enforce(terminalIndex == events.length - 1, provider ~ " stream must end with its " ~ terminalName ~ " line");
	const terminal = terminalFor(provider, lines[$ - 1]);
	switch (provider)
	{
	case "claude":
		return enforceClaudeResult(events, terminal);
	case "codex":
		return enforceCodexTurn(events, terminal);
	default:
		const status = events[$ - 1]["status"].opt!string;
		enforce((status == "success" || status == "error") && terminal == Terminal(true, status == "success"),
			provider ~ " result line terminal ok does not match status");
	}
}

/// How a provider's CLI stream opens and which event types end it.
private struct StreamRule
{
	string provider;
	string first;
	string[] terminals;
}

private immutable StreamRule[] streamRules = [
	StreamRule("claude", "system/init", ["result"]),
	StreamRule("gemini", "init", ["result"]),
	StreamRule("codex", "thread.started", ["turn.completed", "turn.failed"]),
];

/// Enforce what a codex stream's last line adds to the shared sequence rules: a completed
/// turn follows an `agent_message` item, and its terminal signal agrees with its type.
private void enforceCodexTurn(const Json[] events, Terminal terminal)
{
	const completed = typeOf(events[$ - 1]) == "turn.completed";
	enforce(!completed || events[0 .. $ - 1].any!(event => typeOf(event) == "item.completed"
			&& event["item"]["type"].opt!string == "agent_message"),
		"codex stream needs an agent_message item before turn.completed");
	enforce(terminal == Terminal(true, completed), "codex turn line terminal ok does not match its type");
}

/// Enforce what a claude stream's result line adds to the shared sequence rules: an assistant
/// line before it, its keys, and an `is_error` that agrees with its terminal signal.
private void enforceClaudeResult(const Json[] events, Terminal terminal)
{
	enforce(events[0 .. $ - 1].any!(event => typeOf(event) == "assistant"),
		"claude stream needs an assistant line before result");
	foreach (key; claudeResultKeys)
		enforce(key in events[$ - 1], "claude result line is missing " ~ key);
	const isError = events[$ - 1]["is_error"];
	enforce(isError.type == Json.Type.bool_ && terminal == Terminal(true, !isError.get!bool),
		"claude result line terminal ok does not match is_error");
}

/// Enforce that every line of `lines` the downstream consumer reads carries the fields it reads,
/// with the JSON types it expects.
void enforceConsumerContract(string provider, const string[] lines)
{
	enforce(["claude", "codex", "gemini"].canFind(provider), "no consumer contract for provider " ~ provider);
	foreach (event; lines.map!parseJsonString)
		foreach (field; consumerFields.filter!(field => (field.provider == provider || field.provider == anyProvider)
				&& field.event == consumedEvent(event)))
			enforceField(provider, event, field);
}

/// The JSON type a consumer expects of a field.
enum FieldKind : string
{
	string_ = "a string",
	number = "a number",
	bool_ = "a bool",
	object = "an object",
}

/// One field the downstream consumer reads: in which provider's stream (`anyProvider` for
/// all), on which event, at which dotted path (`*` stands for every key of an object), with
/// which JSON type, and whether it must be present.
struct ConsumerField
{
	string provider;
	string event;
	string path;
	FieldKind kind;
	bool required = true;
}

/// ditto
enum anyProvider = "*";

/// The fields the downstream consumer (Floor) reads from a run's lines, CLI or batch.
/// A field of the wrong type makes the consumer drop the whole line, so types are part of it.
/// Floor parses no codex line yet, so a codex run's final text and usage don't reach it (CLI
/// or batch); the codex rows pin the minimum a parser would need: the turn's token usage and
/// the agent_message text.
immutable ConsumerField[] consumerFields = [
	ConsumerField("claude", "result", "type", FieldKind.string_),
	ConsumerField("claude", "result", "result", FieldKind.string_),
	ConsumerField("claude", "result", "is_error", FieldKind.bool_),
	ConsumerField("claude", "result", "total_cost_usd", FieldKind.number),
	ConsumerField("claude", "result", "num_turns", FieldKind.number),
	ConsumerField("claude", "result", "duration_ms", FieldKind.number),
	ConsumerField("claude", "result", "usage", FieldKind.object),
	ConsumerField("claude", "result", "usage.input_tokens", FieldKind.number),
	ConsumerField("claude", "result", "usage.output_tokens", FieldKind.number),
	ConsumerField("claude", "result", "usage.cache_read_input_tokens", FieldKind.number, false),
	ConsumerField("claude", "result", "usage.cache_creation_input_tokens", FieldKind.number, false),
	ConsumerField("claude", "result", "modelUsage", FieldKind.object),
	ConsumerField("claude", "result", "modelUsage.*", FieldKind.object),
	ConsumerField("claude", "result", "modelUsage.*.inputTokens", FieldKind.number),
	ConsumerField("claude", "result", "modelUsage.*.outputTokens", FieldKind.number),
	ConsumerField("claude", "result", "modelUsage.*.cacheReadInputTokens", FieldKind.number),
	ConsumerField("claude", "result", "modelUsage.*.cacheCreationInputTokens", FieldKind.number),
	ConsumerField("claude", "result", "modelUsage.*.costUSD", FieldKind.number),
	ConsumerField("claude", "system/init", "type", FieldKind.string_),
	ConsumerField("claude", "system/init", "subtype", FieldKind.string_),
	ConsumerField("claude", "system/init", "apiKeySource", FieldKind.string_),
	ConsumerField("gemini", "result", "type", FieldKind.string_),
	ConsumerField("gemini", "result", "status", FieldKind.string_),
	ConsumerField("gemini", "result", "error", FieldKind.object, false),
	ConsumerField("gemini", "result", "error.message", FieldKind.string_, false),
	ConsumerField("gemini", "result", "stats", FieldKind.object),
	ConsumerField("gemini", "result", "stats.input", FieldKind.number),
	ConsumerField("gemini", "result", "stats.cached", FieldKind.number),
	ConsumerField("gemini", "result", "stats.output_tokens", FieldKind.number),
	ConsumerField("gemini", "result", "stats.duration_ms", FieldKind.number),
	ConsumerField("gemini", "result", "stats.models", FieldKind.object),
	ConsumerField("gemini", "result", "stats.models.*", FieldKind.object),
	ConsumerField("gemini", "result", "stats.models.*.input", FieldKind.number),
	ConsumerField("gemini", "result", "stats.models.*.cached", FieldKind.number),
	ConsumerField("gemini", "result", "stats.models.*.output_tokens", FieldKind.number),
	ConsumerField("gemini", "init", "type", FieldKind.string_),
	ConsumerField("gemini", "message/assistant", "type", FieldKind.string_),
	ConsumerField("gemini", "message/assistant", "role", FieldKind.string_),
	ConsumerField("gemini", "message/assistant", "content", FieldKind.string_),
	ConsumerField("codex", "turn.completed", "type", FieldKind.string_),
	ConsumerField("codex", "turn.completed", "usage", FieldKind.object),
	ConsumerField("codex", "turn.completed", "usage.input_tokens", FieldKind.number),
	ConsumerField("codex", "turn.completed", "usage.cached_input_tokens", FieldKind.number),
	ConsumerField("codex", "turn.completed", "usage.output_tokens", FieldKind.number),
	ConsumerField("codex", "item.completed/agent_message", "item.text", FieldKind.string_),
	ConsumerField(anyProvider, "lifecycle", "kind", FieldKind.string_),
	ConsumerField(anyProvider, "lifecycle", "phase", FieldKind.string_),
	ConsumerField(anyProvider, "lifecycle", "status", FieldKind.string_),
	ConsumerField(anyProvider, "lifecycle", "tool", FieldKind.string_, false),
	ConsumerField(anyProvider, "lifecycle", "reason", FieldKind.string_, false),
	ConsumerField(anyProvider, "lifecycle", "exitCode", FieldKind.number, false),
];

/// Enforce `field` on `event`: present wherever its parent object is when required, and of its
/// kind wherever present.
private void enforceField(string provider, const Json event, const ConsumerField field)
{
	const segments = field.path.split(".");
	const leaf = segments[$ - 1];
	foreach (parent; valuesAt(event, segments[0 .. $ - 1]).filter!(parent => parent.type == Json.Type.object))
	{
		enforce(leaf == "*" || !field.required || leaf in parent,
			format!"%s %s field %s is missing"(provider, field.event, field.path));
		foreach (value; valuesAt(parent, [leaf]))
			enforce(isKind(value, field.kind),
				format!"%s %s field %s must be %s"(provider, field.event, field.path, cast(string) field.kind));
	}
}

/// Which `consumerFields` event `event` is: `lifecycle`, `system/<subtype>`, `message/<role>`,
/// `item.completed/<item type>`, or its `type`.
private string consumedEvent(const Json event)
{
	if (event["kind"].opt!string == "lifecycle")
		return "lifecycle";
	const type = event["type"].opt!string;
	if (type == "system")
		return "system/" ~ event["subtype"].opt!string;
	if (type == "item.completed")
		return "item.completed/" ~ event["item"]["type"].opt!string;
	return type == "message" ? "message/" ~ event["role"].opt!string : type;
}

/// The values at `path` under `node`, a `*` segment expanding to every value of an object.
private const(Json)[] valuesAt(const Json node, const string[] path)
{
	if (path.length == 0)
		return [node];
	if (node.type != Json.Type.object)
		return null;
	if (path[0] == "*")
		return node.byValue.map!(child => valuesAt(child, path[1 .. $])).join;
	const child = node[path[0]];
	return child.type == Json.Type.undefined ? null : valuesAt(child, path[1 .. $]);
}

private bool isKind(const Json value, FieldKind kind)
{
	final switch (kind)
	{
	case FieldKind.string_:
		return value.type == Json.Type.string;
	case FieldKind.number:
		return value.type == Json.Type.int_ || value.type == Json.Type.float_ || value.type == Json.Type.bigInt;
	case FieldKind.bool_:
		return value.type == Json.Type.bool_;
	case FieldKind.object:
		return value.type == Json.Type.object;
	}
}

/// One event's structure with values ignored: its `type` and its sorted top-level keys.
struct EventShape
{
	string type;
	string[] keys;
}

/// The structure of each line in `lines`, so two streams can be compared without their values.
EventShape[] eventShape(const string[] lines)
{
	return lines.map!parseJsonString
		.map!(event => EventShape(typeOf(event), event.byKeyValue.map!(entry => entry.key).array.sort.release))
		.array;
}

/// For each line of `lines`, the top-level keys that no line of `recorded` with the same `type`
/// carries: what a translated stream adds over a recorded one, values ignored.
string[][] keysAbsentFrom(const string[] recorded, const string[] lines)
{
	const known = eventShape(recorded);
	return eventShape(lines).map!(shape => shape.keys
			.filter!(key => !known.any!(cli => cli.type == shape.type && cli.keys.canFind(key)))
			.array)
		.array;
}

private immutable claudeResultKeys = ["is_error", "result", "usage", "total_cost_usd", "session_id"];

private string typeOf(const Json event)
{
	return event["type"].get!string;
}


unittest // recorded claude cli stream passes the contract
{
	const lines = import("events/claude-cli.jsonl").splitLines;
	({ enforceEventContract("claude", lines); }).should.not.throwAnyException;
}

unittest // claude cli stream without its result line is rejected
{
	const lines = import("events/claude-cli.jsonl").splitLines
		.filter!(line => parseJsonString(line)["type"].get!string != "result").array;
	({ enforceEventContract("claude", lines); }).should.throwException!Exception;
}

unittest // claude cli stream not starting with system init is rejected
{
	const lines = import("events/claude-cli.jsonl").splitLines[1 .. $];
	({ enforceEventContract("claude", lines); }).should.throwException!Exception
		.withMessage.equal("claude stream must start with system/init");
}

unittest // claude cli stream without an assistant line before result is rejected
{
	const recorded = import("events/claude-cli.jsonl").splitLines;
	const lines = [recorded[0], recorded[2]];
	({ enforceEventContract("claude", lines); }).should.throwException!Exception
		.withMessage.equal("claude stream needs an assistant line before result");
}

unittest // claude cli stream with a line after result is rejected
{
	const recorded = import("events/claude-cli.jsonl").splitLines;
	const lines = recorded ~ recorded[1];
	({ enforceEventContract("claude", lines); }).should.throwException!Exception
		.withMessage.equal("claude stream must end with its result line");
}

unittest // claude result line without total_cost_usd is rejected
{
	const recorded = import("events/claude-cli.jsonl").splitLines;
	auto result = parseJsonString(recorded[2]);
	result.remove("total_cost_usd");
	const lines = recorded[0 .. 2] ~ result.toString;
	({ enforceEventContract("claude", lines); }).should.throwException!Exception
		.withMessage.equal("claude result line is missing total_cost_usd");
}

unittest // claude result line with string is_error "true" is rejected as terminal ok mismatch
{
	const recorded = import("events/claude-cli.jsonl").splitLines;
	auto result = parseJsonString(recorded[2]);
	result["is_error"] = "true";
	const lines = recorded[0 .. 2] ~ result.toString;
	({ enforceEventContract("claude", lines); }).should.throwException!Exception
		.withMessage.equal("claude result line terminal ok does not match is_error");
}

unittest // unknown provider "mistral" is rejected
{
	const lines = import("events/claude-cli.jsonl").splitLines;
	({ enforceEventContract("mistral", lines); }).should.throwException!Exception
		.withMessage.equal("no event contract for provider mistral");
}

unittest // recorded claude cli stream satisfies the consumer contract
{
	const lines = import("events/claude-cli.jsonl").splitLines;
	({ enforceConsumerContract("claude", lines); }).should.not.throwAnyException;
}

unittest // claude result line with num_turns "1" as a string is rejected
{
	const recorded = import("events/claude-cli.jsonl").splitLines;
	auto result = parseJsonString(recorded[2]);
	result["num_turns"] = "1";
	({ enforceConsumerContract("claude", recorded[0 .. 2] ~ result.toString); }).should.throwException!Exception
		.withMessage.equal("claude result field num_turns must be a number");
}

unittest // claude result line without duration_ms is rejected
{
	const recorded = import("events/claude-cli.jsonl").splitLines;
	auto result = parseJsonString(recorded[2]);
	result.remove("duration_ms");
	({ enforceConsumerContract("claude", recorded[0 .. 2] ~ result.toString); }).should.throwException!Exception
		.withMessage.equal("claude result field duration_ms is missing");
}

unittest // recorded gemini cli stream satisfies the consumer contract
{
	const lines = import("events/gemini-cli.jsonl").splitLines;
	({ enforceConsumerContract("gemini", lines); }).should.not.throwAnyException;
}

unittest // gemini result line with stats.input "7849" as a string is rejected
{
	const recorded = import("events/gemini-cli.jsonl").splitLines;
	auto result = parseJsonString(recorded[$ - 1]);
	result["stats"]["input"] = "7849";
	({ enforceConsumerContract("gemini", recorded[0 .. $ - 1] ~ result.toString); }).should.throwException!Exception
		.withMessage.equal("gemini result field stats.input must be a number");
}

unittest // gemini assistant message with content as an array of parts is rejected
{
	const recorded = import("events/gemini-cli.jsonl").splitLines;
	auto message = parseJsonString(recorded[2]);
	message["content"] = parseJsonString(`[{"text":"ok"}]`);
	({ enforceConsumerContract("gemini", recorded[0 .. 2] ~ message.toString ~ recorded[3]); })
		.should.throwException!Exception.withMessage.equal("gemini message/assistant field content must be a string");
}

unittest // gemini result line without stats.duration_ms is rejected
{
	const recorded = import("events/gemini-cli.jsonl").splitLines;
	auto result = parseJsonString(recorded[$ - 1]);
	result["stats"].remove("duration_ms");
	({ enforceConsumerContract("gemini", recorded[0 .. $ - 1] ~ result.toString); }).should.throwException!Exception
		.withMessage.equal("gemini result field stats.duration_ms is missing");
}

unittest // recorded gemini cli api error stream satisfies the consumer contract
{
	const lines = import("events/gemini-cli-error.jsonl").splitLines;
	({ enforceConsumerContract("gemini", lines); }).should.not.throwAnyException;
}

unittest // recorded gemini cli success and api error streams pass the event contract
{
	({
		enforceEventContract("gemini", import("events/gemini-cli.jsonl").splitLines);
		enforceEventContract("gemini", import("events/gemini-cli-error.jsonl").splitLines);
	}).should.not.throwAnyException;
}

unittest // gemini result line with status "failed" is rejected as terminal ok mismatch
{
	const recorded = import("events/gemini-cli.jsonl").splitLines;
	auto result = parseJsonString(recorded[$ - 1]);
	result["status"] = "failed";
	({ enforceEventContract("gemini", recorded[0 .. $ - 1] ~ result.toString); }).should.throwException!Exception
		.withMessage.equal("gemini result line terminal ok does not match status");
}

unittest // gemini stream starting with its user message is rejected
{
	const lines = import("events/gemini-cli.jsonl").splitLines[1 .. $];
	({ enforceEventContract("gemini", lines); }).should.throwException!Exception
		.withMessage.equal("gemini stream must start with init");
}

unittest // recorded codex cli success and api error streams pass the event contract
{
	({
		enforceEventContract("codex", import("events/codex-cli.jsonl").splitLines);
		enforceEventContract("codex", import("events/codex-cli-error.jsonl").splitLines);
	}).should.not.throwAnyException;
}

unittest // codex stream completing its turn without an agent_message item is rejected
{
	const recorded = import("events/codex-cli.jsonl").splitLines;
	const lines = recorded[0 .. 2] ~ recorded[3];
	({ enforceEventContract("codex", lines); }).should.throwException!Exception
		.withMessage.equal("codex stream needs an agent_message item before turn.completed");
}

unittest // codex stream with an item after turn.completed is rejected
{
	const recorded = import("events/codex-cli.jsonl").splitLines;
	({ enforceEventContract("codex", recorded ~ recorded[2]); }).should.throwException!Exception
		.withMessage.equal("codex stream must end with its turn.completed or turn.failed line");
}

unittest // codex stream starting with turn.started is rejected
{
	({ enforceEventContract("codex", import("events/codex-cli.jsonl").splitLines[1 .. $]); })
		.should.throwException!Exception.withMessage.equal("codex stream must start with thread.started");
}

unittest // recorded codex cli success and api error streams satisfy the consumer contract
{
	({
		enforceConsumerContract("codex", import("events/codex-cli.jsonl").splitLines);
		enforceConsumerContract("codex", import("events/codex-cli-error.jsonl").splitLines);
	}).should.not.throwAnyException;
}

unittest // codex turn.completed with usage.output_tokens "5" as a string is rejected
{
	const recorded = import("events/codex-cli.jsonl").splitLines;
	auto turn = parseJsonString(recorded[$ - 1]);
	turn["usage"]["output_tokens"] = "5";
	({ enforceConsumerContract("codex", recorded[0 .. $ - 1] ~ turn.toString); }).should.throwException!Exception
		.withMessage.equal("codex turn.completed field usage.output_tokens must be a number");
}

unittest // codex agent_message item with text as an array of parts is rejected
{
	const recorded = import("events/codex-cli.jsonl").splitLines;
	auto item = parseJsonString(recorded[2]);
	item["item"]["text"] = parseJsonString(`[{"text":"ok"}]`);
	({ enforceConsumerContract("codex", recorded[0 .. 2] ~ item.toString ~ recorded[3]); })
		.should.throwException!Exception
		.withMessage.equal("codex item.completed/agent_message field item.text must be a string");
}
