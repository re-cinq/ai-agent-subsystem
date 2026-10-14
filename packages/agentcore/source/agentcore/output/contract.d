module agentcore.output.contract;

import std.algorithm : any, countUntil, filter, map, sort;
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
	enforce(provider == "claude", "no event contract for provider " ~ provider);
	const events = lines.map!parseJsonString.array;
	enforce(events.length > 0 && isSystemInit(events[0]),
		provider ~ " stream must start with system/init");
	const resultIndex = events.countUntil!(event => typeOf(event) == "result");
	enforce(resultIndex >= 0, provider ~ " stream is missing its result line");
	enforce(events[0 .. resultIndex].any!(event => typeOf(event) == "assistant"),
		provider ~ " stream needs an assistant line before result");
	enforce(resultIndex == events.length - 1, provider ~ " stream must end with its result line");
	foreach (key; claudeResultKeys)
		enforce(key in events[resultIndex], provider ~ " result line is missing " ~ key);
	const isError = events[resultIndex]["is_error"];
	enforce(isError.type == Json.Type.bool_
		&& terminalFor(provider, lines[$ - 1]) == Terminal(true, !isError.get!bool),
		provider ~ " result line terminal ok does not match is_error");
}

/// Enforce that every line of `lines` the downstream consumer reads carries the fields it reads,
/// with the JSON types it expects.
void enforceConsumerContract(string provider, const string[] lines)
{
	enforce(provider == "claude", "no consumer contract for provider " ~ provider);
	foreach (event; lines.map!parseJsonString)
		foreach (field; consumerFields.filter!(field => field.event == consumedEvent(event)))
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

/// One field the downstream consumer reads: on which event, at which dotted path (`*` stands
/// for every key of an object), with which JSON type, and whether it must be present.
struct ConsumerField
{
	string event;
	string path;
	FieldKind kind;
	bool required = true;
}

/// The fields the downstream consumer (Floor) reads from a claude run's lines, CLI or batch.
/// A field of the wrong type makes the consumer drop the whole line, so types are part of it.
immutable ConsumerField[] consumerFields = [
	ConsumerField("result", "type", FieldKind.string_),
	ConsumerField("result", "result", FieldKind.string_),
	ConsumerField("result", "is_error", FieldKind.bool_),
	ConsumerField("result", "total_cost_usd", FieldKind.number),
	ConsumerField("result", "num_turns", FieldKind.number),
	ConsumerField("result", "duration_ms", FieldKind.number),
	ConsumerField("result", "usage", FieldKind.object),
	ConsumerField("result", "usage.input_tokens", FieldKind.number),
	ConsumerField("result", "usage.output_tokens", FieldKind.number),
	ConsumerField("result", "usage.cache_read_input_tokens", FieldKind.number, false),
	ConsumerField("result", "usage.cache_creation_input_tokens", FieldKind.number, false),
	ConsumerField("result", "modelUsage", FieldKind.object),
	ConsumerField("result", "modelUsage.*", FieldKind.object),
	ConsumerField("result", "modelUsage.*.inputTokens", FieldKind.number),
	ConsumerField("result", "modelUsage.*.outputTokens", FieldKind.number),
	ConsumerField("result", "modelUsage.*.cacheReadInputTokens", FieldKind.number),
	ConsumerField("result", "modelUsage.*.cacheCreationInputTokens", FieldKind.number),
	ConsumerField("result", "modelUsage.*.costUSD", FieldKind.number),
	ConsumerField("system/init", "type", FieldKind.string_),
	ConsumerField("system/init", "subtype", FieldKind.string_),
	ConsumerField("system/init", "apiKeySource", FieldKind.string_),
	ConsumerField("lifecycle", "kind", FieldKind.string_),
	ConsumerField("lifecycle", "phase", FieldKind.string_),
	ConsumerField("lifecycle", "status", FieldKind.string_),
	ConsumerField("lifecycle", "tool", FieldKind.string_, false),
	ConsumerField("lifecycle", "reason", FieldKind.string_, false),
	ConsumerField("lifecycle", "exitCode", FieldKind.number, false),
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

/// Which `consumerFields` event `event` is: `lifecycle`, `system/<subtype>`, or its `type`.
private string consumedEvent(const Json event)
{
	if (event["kind"].opt!string == "lifecycle")
		return "lifecycle";
	const type = event["type"].opt!string;
	return type == "system" ? "system/" ~ event["subtype"].opt!string : type;
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

private immutable claudeResultKeys = ["is_error", "result", "usage", "total_cost_usd", "session_id"];

private string typeOf(const Json event)
{
	return event["type"].get!string;
}

private bool isSystemInit(const Json event)
{
	return typeOf(event) == "system" && event["subtype"].opt!string == "init";
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
