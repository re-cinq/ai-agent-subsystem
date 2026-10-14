module agentcore.batch.anthropic;

import agentcore.batch.provider : BatchPoll, BatchProvider, BatchRequest, BatchState, HttpRequest,
	HttpResponse, HttpTransport;
import agentcore.batch.pricing : batchCostUsd;
import std.exception : enforce;
import std.format : format;
import std.algorithm : filter, map;
import std.array : join;
import vibe.data.json : Json, parseJsonString;

version (unittest)
{
	import agentcore.output.contract : enforceConsumerContract, enforceEventContract, eventShape;
	import std.string : splitLines;
	import std.algorithm : canFind;
	import std.array : array;
	import agentcore.output.terminal : Terminal, terminalFor;
	import fluent.asserts;
}

/// Body for `POST /v1/messages/batches` carrying `request` as the batch's only entry; a
/// schema becomes structured output (`output_config.format`).
Json requestBody(const BatchRequest request)
{
	auto params = Json([
		"model": Json(request.model),
		"max_tokens": Json(request.maxTokens),
		"messages": Json([Json(["role": Json("user"), "content": Json(request.prompt)])]),
	]);
	if (hasSchema(request.schema))
		params["output_config"] = Json(["format": Json(["type": Json("json_schema"),
				"schema": request.schema.clone])]);
	return Json(["requests": Json([Json(["custom_id": Json(request.customId), "params": params])])]);
}

/// Read a poll of `batch`; `resultLine` is the batch's results JSONL line once it has ended.
BatchPoll parsePoll(const Json batch, string resultLine)
{
	if (batch["processing_status"].get!string != "ended")
		return BatchPoll(BatchState.pending);
	const result = parseJsonString(resultLine)["result"];
	if (result["type"].get!string == "succeeded")
		return BatchPoll(BatchState.succeeded, result["message"]);
	return BatchPoll(BatchState.failed, Json.undefined, failureMessage(result));
}

/// Translate `poll` into the claude `stream-json` lines the CLI emits for a single-turn, no-tool run.
/// Like the CLI's assistant event, the message keeps only its `text` blocks (thinking is dropped),
/// and `result` is their joined text.
/// The batch API reports no cost or timing: `total_cost_usd` is the batch-discounted price of the
/// message's usage (0 for a model missing from `agentcore.batch.pricing`) and the durations are 0. A failed
/// poll becomes an assistant message carrying the error text and an `is_error` result, as the CLI
/// reports an API error.
string[] toCliEvents(const BatchPoll poll, string sessionId)
{
	const succeeded = poll.state == BatchState.succeeded;
	const message = succeeded ? withTextOnly(poll.result) : errorMessage(poll.error);
	auto init = Json([
		"type": Json("system"),
		"subtype": Json("init"),
		"cwd": Json(""),
		"session_id": Json(sessionId),
		"tools": Json.emptyArray,
		"mcp_servers": Json.emptyArray,
		"model": Json(message["model"].opt!string("")),
		"permissionMode": Json("default"),
		"apiKeySource": Json("ANTHROPIC_API_KEY"),
	]);
	auto assistant = Json(["type": Json("assistant"), "message": message.clone,
		"session_id": Json(sessionId)]);
	auto result = Json([
		"type": Json("result"),
		"subtype": Json(succeeded ? "success" : "error_during_execution"),
		"is_error": Json(!succeeded),
		"duration_ms": Json(0),
		"duration_api_ms": Json(0),
		"num_turns": Json(1),
		"result": Json(messageText(message)),
		"session_id": Json(sessionId),
		"usage": message["usage"].clone,
		"total_cost_usd": Json(messageCostUsd(message)),
		"modelUsage": modelUsage(message),
	]);
	return [init.toString, assistant.toString, result.toString];
}

/// The Message Batches API, authenticated with `apiKey`, over `transport`.
final class AnthropicBatchProvider : BatchProvider
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
		return call("POST", batchesUrl, requestBody(request).toString)["id"].get!string;
	}

	BatchPoll poll(string id)
	{
		const batch = call("GET", batchUrl(id), "");
		if (batch["processing_status"].get!string != "ended")
			return parsePoll(batch, "");
		return parsePoll(batch, firstLine(send("GET", batch["results_url"].get!string, "")));
	}

	void cancel(string id)
	{
		send("POST", batchUrl(id) ~ "/cancel", "");
	}

	void cleanup(string id)
	{
		send("DELETE", batchUrl(id), "");
	}

	private Json call(string method, string url, string body)
	{
		return parseJsonString(send(method, url, body));
	}

	private string send(string method, string url, string body)
	{
		auto headers = ["x-api-key": apiKey, "anthropic-version": anthropicVersion,
			"content-type": "application/json"];
		const response = transport(HttpRequest(method, url, headers, body));
		enforce(response.status >= 200 && response.status < 300,
			format!"anthropic %s %s: HTTP %s: %s"(method, url, response.status, response.body));
		return response.body;
	}
}

/// The first line of a results JSONL body: a batch here always holds exactly one request.
private string firstLine(string jsonl) @safe pure
{
	import std.string : lineSplitter;

	return jsonl.lineSplitter.front;
}

private enum batchesUrl = "https://api.anthropic.com/v1/messages/batches";
private enum anthropicVersion = "2023-06-01";

private string batchUrl(string id) @safe pure
{
	return batchesUrl ~ "/" ~ id;
}

private Json errorMessage(string error)
{
	return Json([
		"type": Json("message"),
		"role": Json("assistant"),
		"content": Json([Json(["type": Json("text"), "text": Json(error)])]),
		"usage": Json(["input_tokens": Json(0), "output_tokens": Json(0)]),
	]);
}

/// `message` with only its `text` content blocks, as the CLI's assistant event carries it:
/// thinking blocks are dropped.
private Json withTextOnly(const Json message)
{
	import std.array : array;

	auto textOnly = message.clone;
	textOnly["content"] = Json(message["content"].byValue
			.filter!(block => block["type"].get!string == "text")
			.map!(block => block.clone)
			.array);
	return textOnly;
}

private string messageText(const Json message)
{
	return message["content"].byValue.map!(block => block["text"].get!string).join;
}

private double messageCostUsd(const Json message)
{
	const usage = message["usage"];
	return batchCostUsd(message["model"].opt!string(""), usage["input_tokens"].get!long,
		usage["output_tokens"].get!long);
}

/// The CLI's per-model usage, `{<model>: {inputTokens, ...}}`, for the one model `message` ran on;
/// empty for an error message, which names no model.
private Json modelUsage(const Json message)
{
	const model = message["model"].opt!string("");
	if (model.length == 0)
		return Json.emptyObject;
	const usage = message["usage"];
	return Json([model: Json([
		"inputTokens": Json(usage["input_tokens"].get!long),
		"outputTokens": Json(usage["output_tokens"].get!long),
		"cacheReadInputTokens": Json(usage["cache_read_input_tokens"].opt!long(0)),
		"cacheCreationInputTokens": Json(usage["cache_creation_input_tokens"].opt!long(0)),
		"costUSD": Json(messageCostUsd(message)),
	])]);
}

private bool hasSchema(const Json schema)
{
	return schema.type != Json.Type.undefined && schema.type != Json.Type.null_;
}

private string failureMessage(const Json result)
{
	const outcome = result["type"].get!string;
	if (outcome != "errored")
		return "batch request " ~ outcome;
	const apiError = result["error"]["error"];
	return apiError["type"].get!string ~ ": " ~ apiError["message"].get!string;
}

unittest // request for claude-sonnet-4-5 with prompt "Say hello" maps to a single messages batch entry
{
	const request = BatchRequest("claude-sonnet-4-5", "Say hello", Json.undefined, 1024, "agent-7c1e");
	(requestBody(request) == parseJsonString(import("batch/anthropic-request.json"))).should.equal(true);
}

unittest // batch with processing_status in_progress polls as pending
{
	const batch = parseJsonString(import("batch/anthropic-batch-in-progress.json"));
	parsePoll(batch, "").state.should.equal(BatchState.pending);
}

unittest // ended batch with a succeeded result polls as succeeded carrying the message
{
	const batch = parseJsonString(import("batch/anthropic-batch-ended.json"));
	const resultLine = import("batch/anthropic-result-succeeded.json");
	const poll = parsePoll(batch, resultLine);
	poll.state.should.equal(BatchState.succeeded);
	(poll.result == parseJsonString(resultLine)["result"]["message"]).should.equal(true);
}

unittest // ended batch with an errored result polls as failed with the api error message
{
	const batch = parseJsonString(import("batch/anthropic-batch-ended.json"));
	const poll = parsePoll(batch, import("batch/anthropic-result-errored.json"));
	poll.state.should.equal(BatchState.failed);
	poll.error.should.equal("invalid_request_error: max_tokens: 1000000 > 64000, which is the maximum"
		~ " allowed number of output tokens for claude-sonnet-4-5");
}

unittest // ended batch with an expired result polls as failed with "batch request expired"
{
	const batch = parseJsonString(import("batch/anthropic-batch-ended.json"));
	const poll = parsePoll(batch, import("batch/anthropic-result-expired.json"));
	poll.state.should.equal(BatchState.failed);
	poll.error.should.equal("batch request expired");
}

unittest // ended batch with a canceled result polls as failed with "batch request canceled"
{
	const batch = parseJsonString(import("batch/anthropic-batch-ended.json"));
	parsePoll(batch, import("batch/anthropic-result-canceled.json"))
		.should.equal(BatchPoll(BatchState.failed, Json.undefined, "batch request canceled"));
}

unittest // batch with processing_status canceling polls as pending
{
	auto batch = parseJsonString(import("batch/anthropic-batch-in-progress.json"));
	batch["processing_status"] = "canceling";
	parsePoll(batch, "").state.should.equal(BatchState.pending);
}

unittest // succeeded batch poll translates to claude events that pass the contract with terminal ok
{
	const batch = parseJsonString(import("batch/anthropic-batch-ended.json"));
	const lines = toCliEvents(parsePoll(batch, import("batch/anthropic-result-succeeded.json")),
		"5f0c2d1e-8a47-4c3b-9e61-2b7d4a9c1f30");
	({ enforceEventContract("claude", lines); }).should.not.throwAnyException;
	terminalFor("claude", lines[$ - 1]).should.equal(Terminal(true, true));
}

unittest // expired batch poll translates to claude events that pass the contract with terminal not ok
{
	const batch = parseJsonString(import("batch/anthropic-batch-ended.json"));
	const lines = toCliEvents(parsePoll(batch, import("batch/anthropic-result-expired.json")),
		"5f0c2d1e-8a47-4c3b-9e61-2b7d4a9c1f30");
	({ enforceEventContract("claude", lines); }).should.not.throwAnyException;
	terminalFor("claude", lines[$ - 1]).should.equal(Terminal(true, false));
	parseJsonString(lines[$ - 1])["result"].get!string.should.equal("batch request expired");
}

unittest // succeeded batch translation of the recorded batch result satisfies the consumer contract
{
	const batch = parseJsonString(import("batch/anthropic-batch-ended.json"));
	const lines = toCliEvents(parsePoll(batch, import("batch/anthropic-result-succeeded.json")), "s1");
	({ enforceConsumerContract("claude", lines); }).should.not.throwAnyException;
}

unittest // succeeded batch translation emits no top-level key the recorded claude cli stream lacks for that event type
{
	const batch = parseJsonString(import("batch/anthropic-batch-ended.json"));
	const lines = toCliEvents(parsePoll(batch, import("batch/anthropic-result-succeeded.json")),
		"5f0c2d1e-8a47-4c3b-9e61-2b7d4a9c1f30");
	const recorded = eventShape(import("events/claude-cli.jsonl").splitLines);
	eventShape(lines).map!(shape => shape.keys.filter!(key => !recorded
			.filter!(cli => cli.type == shape.type)
			.front.keys.canFind(key)).array)
		.array.should.equal([string[].init, string[].init, string[].init]);
}

version (unittest)
{
	import agentcore.batch.provider : HttpRequest, HttpResponse;

	/// Records each request and answers with the next scripted response.
	private struct FakeTransport
	{
		HttpResponse[] responses;
		HttpRequest[] requests;

		HttpResponse send(HttpRequest request)
		{
			requests ~= request;
			const response = responses[0];
			responses = responses[1 .. $];
			return response;
		}
	}

	private enum anthropicHeaders = [
		"x-api-key": "sk-ant-test", "anthropic-version": "2023-06-01", "content-type": "application/json"
	];
}

unittest // submit POSTs the request body to /v1/messages/batches with the api key and returns msgbatch_01
{
	auto transport = FakeTransport([HttpResponse(200, `{"id":"msgbatch_01","processing_status":"in_progress"}`)]);
	auto provider = new AnthropicBatchProvider("sk-ant-test", &transport.send);
	const request = BatchRequest("claude-sonnet-4-5", "Say hello", Json.undefined, 1024, "agent-7c1e");

	provider.submit(request).should.equal("msgbatch_01");
	transport.requests.should.equal([
		HttpRequest("POST", "https://api.anthropic.com/v1/messages/batches", anthropicHeaders,
			requestBody(request).toString)
	]);
}

unittest // submit answered 401 throws naming the status and the error body
{
	auto transport = FakeTransport([HttpResponse(401, `{"type":"error"}`)]);
	auto provider = new AnthropicBatchProvider("sk-ant-test", &transport.send);

	provider.submit(BatchRequest("claude-sonnet-4-5", "Say hello", Json.undefined, 1024, "agent-7c1e"))
		.should.throwException!Exception.withMessage(
			`anthropic POST https://api.anthropic.com/v1/messages/batches: HTTP 401: {"type":"error"}`);
}

unittest // poll of an in_progress batch GETs only the batch and reports pending
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/anthropic-batch-in-progress.json"))]);
	auto provider = new AnthropicBatchProvider("sk-ant-test", &transport.send);

	provider.poll("msgbatch_01").state.should.equal(BatchState.pending);
	transport.requests.should.equal([
		HttpRequest("GET", "https://api.anthropic.com/v1/messages/batches/msgbatch_01", anthropicHeaders, "")
	]);
}

unittest // poll of an ended batch GETs its results_url and reports the succeeded result line
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/anthropic-batch-ended.json")),
		HttpResponse(200, import("batch/anthropic-result-succeeded.json") ~ "\n")]);
	auto provider = new AnthropicBatchProvider("sk-ant-test", &transport.send);

	const ended = parseJsonString(import("batch/anthropic-batch-ended.json"));

	provider.poll(ended["id"].get!string).should.equal(
		parsePoll(ended, import("batch/anthropic-result-succeeded.json")));
	transport.requests[1].should.equal(HttpRequest("GET", ended["results_url"].get!string, anthropicHeaders, ""));
}

unittest // cancel POSTs to /v1/messages/batches/msgbatch_01/cancel
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/anthropic-batch-in-progress.json"))]);
	auto provider = new AnthropicBatchProvider("sk-ant-test", &transport.send);

	provider.cancel("msgbatch_01");

	transport.requests.should.equal([HttpRequest("POST",
		"https://api.anthropic.com/v1/messages/batches/msgbatch_01/cancel", anthropicHeaders, "")]);
}

unittest // cleanup DELETEs /v1/messages/batches/msgbatch_01
{
	auto transport = FakeTransport([HttpResponse(200, `{"id":"msgbatch_01","type":"message_batch_deleted"}`)]);
	auto provider = new AnthropicBatchProvider("sk-ant-test", &transport.send);

	provider.cleanup("msgbatch_01");

	transport.requests.should.equal([HttpRequest("DELETE",
		"https://api.anthropic.com/v1/messages/batches/msgbatch_01", anthropicHeaders, "")]);
}

unittest // succeeded claude-opus-5-5 poll with 18 input and 4 output tokens reports total_cost_usd 0.000076
{
	auto message = parseJsonString(import("batch/anthropic-result-succeeded.json"))["result"]["message"];
	message["model"] = "claude-opus-5-5";
	const lines = toCliEvents(BatchPoll(BatchState.succeeded, message), "s1");
	parseJsonString(lines[$ - 1])["total_cost_usd"].to!double.should.be.approximately(0.000076, 1e-12);
}

unittest // usage with 40 cache_creation and 900 cache_read tokens passes through to the result unchanged
{
	auto message = parseJsonString(import("batch/anthropic-result-succeeded.json"))["result"]["message"];
	message["usage"]["cache_creation_input_tokens"] = 40;
	message["usage"]["cache_read_input_tokens"] = 900;

	parseJsonString(toCliEvents(BatchPoll(BatchState.succeeded, message), "s1")[$ - 1])["usage"]
		.should.equal(message["usage"]);
}

unittest // succeeded poll with a thinking block before two text blocks emits only the text blocks and their joined text
{
	const batch = parseJsonString(import("batch/anthropic-batch-ended.json"));
	const lines = toCliEvents(parsePoll(batch, import("batch/anthropic-result-thinking.json")), "s1");

	[parseJsonString(lines[1])["message"]["content"], parseJsonString(lines[2])["result"]].should.equal([
		parseJsonString(`[{"type":"text","text":"Hello! "},{"type":"text","text":"How can I help?"}]`),
		Json("Hello! How can I help?")
	]);
}

unittest // request with an object schema sends it as params.output_config json_schema format
{
	const schema = parseJsonString(`{"type":"object","properties":{"ok":{"type":"boolean"}}}`);
	const request = BatchRequest("claude-opus-5-5", "Check", schema, 1024, "agent-7c1e");

	requestBody(request)["requests"][0]["params"]["output_config"].should.equal(
		parseJsonString(`{"format":{"type":"json_schema","schema":{"type":"object","properties":{"ok":{"type":"boolean"}}}}}`));
}

unittest // expired poll, which names no model, reports an empty modelUsage
{
	const lines = toCliEvents(BatchPoll(BatchState.failed, Json.undefined, "batch request expired"), "s1");
	parseJsonString(lines[$ - 1])["modelUsage"].should.equal(Json.emptyObject);
}
