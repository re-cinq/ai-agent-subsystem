module agentcore.batch.gemini;

import agentcore.batch.provider : BatchPoll, BatchProvider, BatchRequest, BatchState, hasSchema, HttpRequest,
	HttpResponse, HttpTransport;
import std.algorithm : canFind;
import std.exception : enforce;
import vibe.data.json : Json, parseJsonString;

version (unittest)
{
	import agentcore.output.contract : enforceConsumerContract, enforceEventContract;
	import agentcore.output.terminal : Terminal, terminalFor;
	import fluent.asserts;
}

/// Body for `POST /v1beta/models/{model}:batchGenerateContent` carrying `request` as the
/// batch's only inline request.
Json requestBody(const BatchRequest request)
{
	auto generationConfig = Json(["maxOutputTokens": Json(request.maxTokens)]);
	if (hasSchema(request.schema))
	{
		generationConfig["responseMimeType"] = "application/json";
		generationConfig["responseJsonSchema"] = request.schema.clone;
	}
	auto inline = Json([
		"request": Json([
			"contents": Json([Json(["role": Json("user"), "parts": Json([Json(["text": Json(request.prompt)])])])]),
			"generationConfig": generationConfig,
		]),
		"metadata": Json(["key": Json(request.customId)]),
	]);
	return Json(["batch": Json([
		"display_name": Json(request.customId),
		"input_config": Json(["requests": Json(["requests": Json([inline])])]),
	])]);
}

/// Read a poll of the batch `operation` (`GET /v1beta/batches/<id>`).
BatchPoll parsePoll(const Json operation)
{
	const state = batchState(operation);
	if (endedStates.canFind(state))
		return BatchPoll(BatchState.failed, Json.undefined, operationFailure(state, operation["error"]));
	if (state != "BATCH_STATE_SUCCEEDED")
		return BatchPoll(BatchState.pending);
	const inlined = operation["response"]["inlinedResponses"]["inlinedResponses"][0];
	const error = inlined["error"];
	if (error.type == Json.Type.object)
		return BatchPoll(BatchState.failed, Json.undefined, statusFailure(error));
	const response = inlined["response"];
	const candidates = response["candidates"];
	if (candidates.type != Json.Type.array || candidates.length == 0)
		return BatchPoll(BatchState.failed, Json.undefined, noCandidates(response["promptFeedback"]));
	return BatchPoll(BatchState.succeeded, response);
}

/// Why a request failed, from its google.rpc.Status `error`: the message, prefixed with
/// the numeric code when the Status carries one.
private string statusFailure(const Json error)
{
	import std.conv : to;

	const message = error["message"].opt!string("");
	const code = error["code"];
	return code.type == Json.Type.int_ ? code.get!long.to!string ~ ": " ~ message : message;
}

/// Why a response came back without candidates: the prompt's block reason when its
/// `promptFeedback` names one.
private string noCandidates(const Json promptFeedback)
{
	const reason = promptFeedback.type == Json.Type.object ? promptFeedback["blockReason"].opt!string("") : "";
	return reason.length ? "response blocked: " ~ reason : "response has no candidates";
}

/// The `BatchState`s a batch ends in without a response.
private immutable endedStates = ["BATCH_STATE_FAILED", "BATCH_STATE_CANCELLED", "BATCH_STATE_EXPIRED"];

/// Why a batch that ended in `state` failed: `batch <state>`, with the operation's `error`
/// message when it carries one.
private string operationFailure(string state, const Json error)
{
	import std.string : toLower;

	const failure = "batch " ~ state["BATCH_STATE_".length .. $].toLower;
	return error.type == Json.Type.object ? failure ~ ": " ~ error["message"].get!string : failure;
}

/// The batch's `BatchState`, which the operation carries in its `metadata` (the batch
/// resource itself carries it at the top level).
private string batchState(const Json operation)
{
	const metadata = operation["metadata"];
	return (metadata.type == Json.Type.object ? metadata : operation)["state"].get!string;
}

/// Translate `poll` into the gemini `stream-json` lines the CLI emits for a single-turn, no-tool run:
/// `init`, the assistant's text as one `message`, then `result` with the CLI's `stats`. The CLI's
/// own echo of the user prompt and its `timestamp`s are left out, and `duration_ms` is 0: the
/// batch reports neither. The CLI emits no cost, so neither does this. A failed poll becomes an
/// `init` and an error `result` carrying the error text, as the CLI reports an API error.
string[] toCliEvents(const BatchPoll poll, string sessionId)
{
	const succeeded = poll.state == BatchState.succeeded;
	const model = succeeded ? poll.result["modelVersion"].opt!string("") : "";
	auto init = Json(["type": Json("init"), "session_id": Json(sessionId), "model": Json(model)]);
	auto result = Json([
		"type": Json("result"),
		"status": Json(succeeded ? "success" : "error"),
		"stats": stats(model, succeeded ? poll.result["usageMetadata"] : Json.emptyObject),
	]);
	if (!succeeded)
	{
		result["error"] = Json(["type": Json("BatchError"), "message": Json(poll.error)]);
		return [init.toString, result.toString];
	}
	auto message = Json(["type": Json("message"), "role": Json("assistant"),
		"content": Json(responseText(poll.result)), "delta": Json(true)]);
	return [init.toString, message.toString, result.toString];
}

/// The Gemini Batch API, authenticated with `apiKey`, over `transport`. A batch is named by
/// its id, the part of the operation name `batches/<id>` after the slash.
final class GeminiBatchProvider : BatchProvider
{
	private string apiKey;
	private HttpTransport transport;

	this(string apiKey, HttpTransport transport)
	{
		this.apiKey = apiKey;
		this.transport = transport;
	}

	string submit(BatchRequest request)
	{
		import std.algorithm : startsWith;

		const url = apiUrl ~ "/models/" ~ request.model ~ ":batchGenerateContent";
		const name = parseJsonString(send("POST", url, requestBody(request).toString))["name"].get!string;
		enforce(name.startsWith(batchPrefix), "gemini batch operation has no batches/ name: " ~ name);
		return name[batchPrefix.length .. $];
	}

	BatchPoll poll(string id)
	{
		return parsePoll(parseJsonString(send("GET", batchUrl(id), "")));
	}

	void cancel(string id)
	{
		send("POST", batchUrl(id) ~ ":cancel", "");
	}

	void cleanup(string id)
	{
		send("DELETE", batchUrl(id), "");
	}

	private string send(string method, string url, string body)
	{
		import std.format : format;

		auto headers = ["x-goog-api-key": apiKey, "content-type": "application/json"];
		const response = transport(HttpRequest(method, url, headers, body));
		enforce(response.status >= 200 && response.status < 300,
			format!"gemini %s %s: HTTP %s: %s"(method, url, response.status, response.body));
		return response.body;
	}
}

private enum apiUrl = "https://generativelanguage.googleapis.com/v1beta";
private enum batchPrefix = "batches/";

private string batchUrl(string id) @safe pure
{
	return apiUrl ~ "/" ~ batchPrefix ~ id;
}

/// The text of a GenerateContentResponse's first candidate: its parts' text joined, thought
/// parts left out as the CLI leaves them out of its messages; "" for a candidate with no parts,
/// as one cut off by `MAX_TOKENS` while thinking has.
private string responseText(const Json response)
{
	import std.algorithm : filter, map;
	import std.array : join;

	const content = response["candidates"][0]["content"];
	if (content.type != Json.Type.object || content["parts"].type != Json.Type.array)
		return "";
	return content["parts"].byValue
		.filter!(part => !part["thought"].opt!bool(false))
		.map!(part => part["text"].opt!string(""))
		.join;
}

/// The CLI's `stats` for one model call with `usage` (a `usageMetadata`): the totals, and the
/// same counts per model under `models`, which is empty when no model answered.
private Json stats(string model, const Json usage)
{
	const prompt = usage["promptTokenCount"].opt!long(0);
	const cached = usage["cachedContentTokenCount"].opt!long(0);
	const output = usage["candidatesTokenCount"].opt!long(0);
	const total = usage["totalTokenCount"].opt!long(prompt + output + usage["thoughtsTokenCount"].opt!long(0));
	auto counts = Json([
		"total_tokens": Json(total),
		"input_tokens": Json(prompt),
		"output_tokens": Json(output),
		"cached": Json(cached),
		"input": Json(prompt > cached ? prompt - cached : 0),
	]);
	auto stats = counts.clone;
	stats["duration_ms"] = 0;
	stats["tool_calls"] = 0;
	stats["models"] = model.length ? Json([model: counts]) : Json.emptyObject;
	return stats;
}

unittest // request with prompt "Say hello" and 1024 max tokens maps to a single inline batch request
{
	const request = BatchRequest("gemini-3.1-flash-lite", "Say hello", Json.undefined, 1024, "agent-7c1e");
	(requestBody(request) == parseJsonString(import("batch/gemini-request.json"))).should.equal(true);
}

unittest // request with an object schema sends it as generationConfig responseJsonSchema with mime type application/json
{
	const schema = parseJsonString(`{"type":"object","properties":{"ok":{"type":"boolean"}}}`);
	const request = BatchRequest("gemini-3.1-flash-lite", "Check", schema, 1024, "agent-7c1e");

	(requestBody(request)["batch"]["input_config"]["requests"]["requests"][0]["request"]["generationConfig"]
		== parseJsonString(`{"maxOutputTokens":1024,"responseMimeType":"application/json",
			"responseJsonSchema":{"type":"object","properties":{"ok":{"type":"boolean"}}}}`)).should.equal(true);
}

unittest // succeeded batch operation polls as succeeded carrying its one inlined GenerateContentResponse
{
	const operation = parseJsonString(import("batch/gemini-batch-succeeded.json"));
	const poll = parsePoll(operation);
	[Json(poll.state == BatchState.succeeded), poll.result].should.equal([Json(true),
		operation["response"]["inlinedResponses"]["inlinedResponses"][0]["response"]]);
}

unittest // succeeded batch whose inlined response is a code 400 Status polls as failed with "400: <message>"
{
	parsePoll(parseJsonString(import("batch/gemini-batch-request-errored.json"))).should.equal(BatchPoll(
		BatchState.failed, Json.undefined,
		"400: The input token count exceeds the maximum number of tokens allowed 1048576."));
}

unittest // succeeded batch whose inlined error Status has no code polls as failed with just its message
{
	auto operation = parseJsonString(import("batch/gemini-batch-request-errored.json"));
	operation["response"]["inlinedResponses"]["inlinedResponses"][0]["error"] = parseJsonString(`{"message":"bad request"}`);
	parsePoll(operation).should.equal(BatchPoll(BatchState.failed, Json.undefined, "bad request"));
}

unittest // failed batch operation polls as failed with "batch failed" and the operation's error message
{
	parsePoll(parseJsonString(import("batch/gemini-batch-failed.json")))
		.should.equal(BatchPoll(BatchState.failed, Json.undefined, "batch failed: Internal error encountered."));
}

unittest // expired and cancelled batch operations without an error poll as failed "batch expired" and "batch cancelled"
{
	auto operation(string state)
	{
		auto pending = parseJsonString(import("batch/gemini-batch-pending.json"));
		pending["metadata"]["state"] = state;
		return parsePoll(pending).error;
	}

	[operation("BATCH_STATE_EXPIRED"), operation("BATCH_STATE_CANCELLED")]
		.should.equal(["batch expired", "batch cancelled"]);
}

unittest // pending and running batch operations poll as pending
{
	auto running = parseJsonString(import("batch/gemini-batch-pending.json"));
	running["metadata"]["state"] = "BATCH_STATE_RUNNING";
	[parsePoll(parseJsonString(import("batch/gemini-batch-pending.json"))).state, parsePoll(running).state]
		.should.equal([BatchState.pending, BatchState.pending]);
}

unittest // operation carrying its state at the top level instead of in metadata polls by that state
{
	auto operation = parseJsonString(import("batch/gemini-batch-failed.json"));
	operation["state"] = operation["metadata"]["state"];
	operation.remove("metadata");
	parsePoll(operation).state.should.equal(BatchState.failed);
}

unittest // succeeded batch poll translates to gemini events that pass both contracts with terminal ok
{
	const lines = toCliEvents(parsePoll(parseJsonString(import("batch/gemini-batch-succeeded.json"))),
		"5f0c2d1e-8a47-4c3b-9e61-2b7d4a9c1f30");
	({
		enforceEventContract("gemini", lines);
		enforceConsumerContract("gemini", lines);
	}).should.not.throwAnyException;
	terminalFor("gemini", lines[$ - 1]).should.equal(Terminal(true, true));
}

unittest // failed batch poll translates to init and an error result carrying the message that pass both contracts
{
	const lines = toCliEvents(parsePoll(parseJsonString(import("batch/gemini-batch-failed.json"))), "s1");
	({
		enforceEventContract("gemini", lines);
		enforceConsumerContract("gemini", lines);
	}).should.not.throwAnyException;
	[Json(terminalFor("gemini", lines[$ - 1]) == Terminal(true, false)), parseJsonString(lines[$ - 1])["error"]]
		.should.equal([Json(true), parseJsonString(`{"type":"BatchError","message":"batch failed: Internal error encountered."}`)]);
}

unittest // succeeded poll with a thought part before two text parts emits only the text parts joined as the message content
{
	auto response = parseJsonString(import("batch/gemini-batch-succeeded.json"))["response"]["inlinedResponses"]
		["inlinedResponses"][0]["response"];
	response["candidates"][0]["content"]["parts"] = parseJsonString(
		`[{"text":"Plan the greeting","thought":true},{"text":"Hello! "},{"text":"How can I help?"}]`);
	const lines = toCliEvents(BatchPoll(BatchState.succeeded, response), "s1");
	parseJsonString(lines[1])["content"].get!string.should.equal("Hello! How can I help?");
}

unittest // usage with 1000 prompt, 900 cached, 4 candidate and 12 thought tokens reports input 100 and total 1016 for gemini-3.1-flash-lite
{
	auto response = parseJsonString(import("batch/gemini-batch-succeeded.json"))["response"]["inlinedResponses"]
		["inlinedResponses"][0]["response"];
	response["usageMetadata"] = parseJsonString(`{"promptTokenCount":1000,"cachedContentTokenCount":900,
		"candidatesTokenCount":4,"thoughtsTokenCount":12,"totalTokenCount":1016}`);
	const counts = parseJsonString(`{"total_tokens":1016,"input_tokens":1000,"output_tokens":4,"cached":900,"input":100}`);
	auto expected = counts.clone;
	expected["duration_ms"] = 0;
	expected["tool_calls"] = 0;
	expected["models"] = Json(["gemini-3.1-flash-lite": counts]);

	(parseJsonString(toCliEvents(BatchPoll(BatchState.succeeded, response), "s1")[$ - 1])["stats"] == expected)
		.should.equal(true);
}

unittest // succeeded and failed batch translations emit no top-level key the recorded gemini cli streams lack for that event type
{
	import agentcore.output.contract : keysAbsentFrom;
	import std.string : splitLines;

	const recorded = import("events/gemini-cli.jsonl").splitLines ~ import("events/gemini-cli-error.jsonl").splitLines;
	const succeeded = toCliEvents(parsePoll(parseJsonString(import("batch/gemini-batch-succeeded.json"))), "s1");
	const failed = toCliEvents(parsePoll(parseJsonString(import("batch/gemini-batch-failed.json"))), "s1");
	keysAbsentFrom(recorded, succeeded ~ failed).should.equal(new string[][5]);
}

version (unittest)
{
	import agentcore.batch.provider : FakeTransport;

	private enum geminiHeaders = ["x-goog-api-key": "gm-test", "content-type": "application/json"];
}

unittest // submit POSTs the request body to models/gemini-3.1-flash-lite:batchGenerateContent with the api key and returns the batch id
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/gemini-batch-pending.json"))]);
	auto provider = new GeminiBatchProvider("gm-test", &transport.send);
	const request = BatchRequest("gemini-3.1-flash-lite", "Say hello", Json.undefined, 1024, "agent-7c1e");

	provider.submit(request).should.equal("8tq3kz0w6x2v5p9r1m4n7b");
	transport.requests.should.equal([HttpRequest("POST",
		"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:batchGenerateContent",
		geminiHeaders, requestBody(request).toString)]);
}

unittest // submit answered 429 throws naming the status and the error body
{
	auto transport = FakeTransport([HttpResponse(429, `{"error":{"code":429}}`)]);
	auto provider = new GeminiBatchProvider("gm-test", &transport.send);

	provider.submit(BatchRequest("gemini-3.1-flash-lite", "Say hello", Json.undefined, 1024, "agent-7c1e"))
		.should.throwException!Exception.withMessage(`gemini POST https://generativelanguage.googleapis.com/v1beta/`
			~ `models/gemini-3.1-flash-lite:batchGenerateContent: HTTP 429: {"error":{"code":429}}`);
}

unittest // poll GETs batches/8tq3kz0w6x2v5p9r1m4n7b and reports its succeeded response
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/gemini-batch-succeeded.json"))]);
	auto provider = new GeminiBatchProvider("gm-test", &transport.send);

	provider.poll("8tq3kz0w6x2v5p9r1m4n7b")
		.should.equal(parsePoll(parseJsonString(import("batch/gemini-batch-succeeded.json"))));
	transport.requests.should.equal([HttpRequest("GET",
		"https://generativelanguage.googleapis.com/v1beta/batches/8tq3kz0w6x2v5p9r1m4n7b", geminiHeaders, "")]);
}

unittest // cancel POSTs to batches/8tq3kz0w6x2v5p9r1m4n7b:cancel
{
	auto transport = FakeTransport([HttpResponse(200, "{}")]);
	auto provider = new GeminiBatchProvider("gm-test", &transport.send);

	provider.cancel("8tq3kz0w6x2v5p9r1m4n7b");

	transport.requests.should.equal([HttpRequest("POST",
		"https://generativelanguage.googleapis.com/v1beta/batches/8tq3kz0w6x2v5p9r1m4n7b:cancel", geminiHeaders, "")]);
}

unittest // cleanup DELETEs batches/8tq3kz0w6x2v5p9r1m4n7b
{
	auto transport = FakeTransport([HttpResponse(200, "{}")]);
	auto provider = new GeminiBatchProvider("gm-test", &transport.send);

	provider.cleanup("8tq3kz0w6x2v5p9r1m4n7b");

	transport.requests.should.equal([HttpRequest("DELETE",
		"https://generativelanguage.googleapis.com/v1beta/batches/8tq3kz0w6x2v5p9r1m4n7b", geminiHeaders, "")]);
}

unittest // succeeded batch whose inlined response was blocked with no candidates polls as failed naming the block reason
{
	auto operation = parseJsonString(import("batch/gemini-batch-succeeded.json"));
	operation["response"]["inlinedResponses"]["inlinedResponses"][0]["response"] = parseJsonString(
		`{"promptFeedback":{"blockReason":"SAFETY"},"usageMetadata":{"promptTokenCount":8,"totalTokenCount":8}}`);
	parsePoll(operation).should.equal(BatchPoll(BatchState.failed, Json.undefined, "response blocked: SAFETY"));
}

unittest // succeeded batch whose inlined response has neither candidates nor prompt feedback polls as failed "response has no candidates"
{
	auto operation = parseJsonString(import("batch/gemini-batch-succeeded.json"));
	operation["response"]["inlinedResponses"]["inlinedResponses"][0]["response"] = parseJsonString(
		`{"usageMetadata":{"promptTokenCount":8,"totalTokenCount":8}}`);
	parsePoll(operation).should.equal(BatchPoll(BatchState.failed, Json.undefined, "response has no candidates"));
}

unittest // succeeded poll whose candidate hit MAX_TOKENS with no content parts emits an empty assistant message
{
	const response = parseJsonString(`{"candidates":[{"content":{"role":"model"},"finishReason":"MAX_TOKENS"}],
		"usageMetadata":{"promptTokenCount":8,"thoughtsTokenCount":1024,"totalTokenCount":1032},
		"modelVersion":"gemini-3.1-flash-lite"}`);
	parseJsonString(toCliEvents(BatchPoll(BatchState.succeeded, response), "s1")[1])["content"].should.equal(Json(""));
}

unittest // succeeded batch whose inlined response has an empty candidates array polls as failed "response has no candidates"
{
	auto operation = parseJsonString(import("batch/gemini-batch-succeeded.json"));
	operation["response"]["inlinedResponses"]["inlinedResponses"][0]["response"]["candidates"] = Json.emptyArray;
	parsePoll(operation).error.should.equal("response has no candidates");
}
