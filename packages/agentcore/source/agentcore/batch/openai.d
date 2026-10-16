module agentcore.batch.openai;

import agentcore.batch.provider : BatchPoll, BatchProvider, BatchRequest, BatchState, hasSchema, HttpRequest,
	HttpResponse, HttpTransport;
import std.algorithm : canFind;
import std.exception : enforce;
import vibe.data.json : Json, parseJsonString;

private enum apiUrl = "https://api.openai.com/v1";
private enum responsesEndpoint = "/v1/responses";

/// The batch input file's one line: a `POST /v1/responses` call carrying `request`, the
/// endpoint the codex CLI talks to.
Json requestLine(const BatchRequest request)
{
	auto body = Json([
		"model": Json(request.model),
		"input": Json(request.prompt),
		"max_output_tokens": Json(request.maxTokens),
	]);
	if (hasSchema(request.schema))
		body["text"] = Json(["format": Json([
			"type": Json("json_schema"),
			"name": Json("output"),
			"schema": request.schema.clone,
			"strict": Json(true),
		])]);
	return Json([
		"custom_id": Json(request.customId),
		"method": Json("POST"),
		"url": Json(responsesEndpoint),
		"body": body,
	]);
}

/// Read a poll of `batch` (`GET /v1/batches/<id>`); `resultLine` is the line its output or
/// error file holds for the batch's one request, read once the batch has completed.
BatchPoll parsePoll(const Json batch, string resultLine)
{
	const status = batch["status"].get!string;
	if (endedStatuses.canFind(status))
		return BatchPoll(BatchState.failed, Json.undefined, batchFailure(status, batch["errors"]));
	if (status != "completed")
		return BatchPoll(BatchState.pending);
	if (resultLine.length == 0)
		return BatchPoll(BatchState.failed, Json.undefined, "batch completed without a result");
	const line = parseJsonString(resultLine);
	const failure = requestFailure(line);
	return failure.length ? BatchPoll(BatchState.failed, Json.undefined, failure)
		: BatchPoll(BatchState.succeeded, line["response"]["body"]);
}

/// Why the request an output or error file `line` answers failed, or "" when its response
/// completed with text: the line's own error, the error body of a non-200 response, the
/// refusal of a completed response with no text, codex's wording for an incomplete response,
/// or a failed response's error.
private string requestFailure(const Json line)
{
	if (line["error"].type == Json.Type.object)
		return line["error"]["message"].get!string;
	const response = line["response"];
	const body = response["body"];
	if (response["status_code"].get!long != 200)
		return body["error"]["message"].get!string;
	switch (body["status"].get!string)
	{
	case "completed":
		return responseText(body).length ? "" : messageParts(body, "refusal", "refusal");
	case "incomplete":
		return "Incomplete response returned, reason: " ~ body["incomplete_details"]["reason"].get!string;
	default:
		return body["error"]["message"].get!string;
	}
}

/// Translate `poll` into the `exec --json` lines the codex CLI emits for a single-turn, no-tool
/// run: `thread.started` with `sessionId` as the thread id, `turn.started`, the response's text
/// as one `agent_message` item, then `turn.completed` with the turn's usage. The CLI emits no
/// cost, so neither does this. A failed poll ends the turn as the CLI ends one on an API
/// error: an `error` line, then `turn.failed`, both carrying the error text.
string[] toCliEvents(const BatchPoll poll, string sessionId)
{
	auto started = Json(["type": Json("thread.started"), "thread_id": Json(sessionId)]);
	auto turn = Json(["type": Json("turn.started")]);
	if (poll.state != BatchState.succeeded)
	{
		auto error = Json(["type": Json("error"), "message": Json(poll.error)]);
		auto failed = Json(["type": Json("turn.failed"), "error": Json(["message": Json(poll.error)])]);
		return [started.toString, turn.toString, error.toString, failed.toString];
	}
	auto message = Json(["type": Json("item.completed"), "item": Json([
		"id": Json("item_0"), "type": Json("agent_message"), "text": Json(responseText(poll.result)),
	])]);
	auto completed = Json(["type": Json("turn.completed"), "usage": usage(poll.result["usage"])]);
	return [started.toString, turn.toString, message.toString, completed.toString];
}

/// The OpenAI Batch API, authenticated with `apiKey`, over `transport`. A batch is named by
/// its batch id; the files it reads and writes are looked up on the batch object when needed.
final class OpenAIBatchProvider : BatchProvider
{
	private string apiKey;
	private HttpTransport transport;

	this(string apiKey, HttpTransport transport)
	{
		this.apiKey = apiKey;
		this.transport = transport;
	}

	/// Upload the request as the batch's one-line input file, then create the batch over it.
	string submit(BatchRequest request)
	{
		const upload = batchInputUpload(request.customId ~ ".jsonl", requestLine(request).toString ~ "\n");
		const file = parseJsonString(send("POST", apiUrl ~ "/files", upload.body, upload.contentType));
		const batch = Json([
			"input_file_id": file["id"],
			"endpoint": Json(responsesEndpoint),
			"completion_window": Json("24h"),
		]);
		return parseJsonString(send("POST", apiUrl ~ "/batches", batch.toString))["id"].get!string;
	}

	/// Read the batch and, once it has completed, the line its output or error file holds.
	BatchPoll poll(string id)
	{
		const batch = parseJsonString(send("GET", batchUrl(id), ""));
		return parsePoll(batch, resultLine(batch));
	}

	/// The first non-empty first line of a completed batch's output file, then its error file;
	/// "" when neither holds one.
	private string resultLine(const Json batch)
	{
		foreach (fileId; resultFileIds(batch))
		{
			const line = firstLine(send("GET", apiUrl ~ "/files/" ~ fileId ~ "/content", ""));
			if (line.length)
				return line;
		}
		return "";
	}

	void cancel(string id)
	{
		send("POST", batchUrl(id) ~ "/cancel", "");
	}

	/// Delete the files the batch holds the prompt and the result in; the batch object
	/// itself cannot be deleted. Every file is tried, a 404 counting as already deleted. A
	/// batch not yet terminal (a cancel stays `cancelling` for up to ~10 minutes, then writes
	/// its output and error files) throws `BatchNotSettled` instead.
	void cleanup(string id)
	{
		import agentcore.batch.provider : BatchNotSettled;
		import std.algorithm : filter, map;
		import std.array : array, join;

		const batch = parseJsonString(send("GET", batchUrl(id), ""));
		const status = batch["status"].get!string;
		enforce(status == "completed" || endedStatuses.canFind(status),
			new BatchNotSettled("openai batch " ~ id ~ " is still " ~ status));
		const failures = batchFileIds(batch)
			.map!(fileId => apiUrl ~ "/files/" ~ fileId)
			.map!(url => deleteFailure(url, exchange("DELETE", url, "")))
			.array
			.filter!(failure => failure.length > 0)
			.array;
		enforce(failures.length == 0, failures.join("; "));
	}

	private string send(string method, string url, string body, string contentType = "application/json")
	{
		const response = exchange(method, url, body, contentType);
		enforceSucceeded(method, url, response);
		return response.body;
	}

	private HttpResponse exchange(string method, string url, string body, string contentType = "application/json")
	{
		auto headers = ["authorization": "Bearer " ~ apiKey, "content-type": contentType];
		return transport(HttpRequest(method, url, headers, body));
	}
}

private void enforceSucceeded(string method, string url, const HttpResponse response)
{
	enforce(succeeded(response), httpFailure(method, url, response));
}

private bool succeeded(const HttpResponse response) @safe pure nothrow
{
	return response.status >= 200 && response.status < 300;
}

private string httpFailure(string method, string url, const HttpResponse response) @safe
{
	import std.format : format;

	return format!"openai %s %s: HTTP %s: %s"(method, url, response.status, response.body);
}

/// Why the DELETE of the file at `url` failed, or "" when it succeeded or the file was
/// already gone (404), as it is when a retried cleanup reaches a file an earlier one deleted.
private string deleteFailure(string url, const HttpResponse response) @safe
{
	return succeeded(response) || response.status == 404 ? "" : httpFailure("DELETE", url, response);
}


private string batchUrl(string id) @safe pure
{
	return apiUrl ~ "/batches/" ~ id;
}

/// The ids of the files `batch` has: its input file, and its output and error files once written.
private const(string)[] batchFileIds(const Json batch)
{
	return fileIds(batch, ["input_file_id", "output_file_id", "error_file_id"]);
}

/// The file ids `batch` holds in `fields`, in order, skipping the null and absent ones.
private const(string)[] fileIds(const Json batch, const string[] fields)
{
	import std.algorithm : filter, map;
	import std.array : array;

	return fields.map!(field => batch[field].opt!string(""))
		.filter!(fileId => fileId.length > 0)
		.array;
}

/// The files that may hold a completed batch's result, output file first; none before the
/// batch completes.
private const(string)[] resultFileIds(const Json batch)
{
	return batch["status"].get!string == "completed" ? fileIds(batch, ["output_file_id", "error_file_id"]) : null;
}

/// The first line of a JSONL file `content`, or "" when it is empty.
private string firstLine(string content) @safe pure
{
	import std.string : lineSplitter;

	auto lines = content.lineSplitter;
	return lines.empty ? "" : lines.front;
}

/// A `multipart/form-data` body uploading `content` as a `purpose=batch` file named `filename`.
private struct Upload
{
	string contentType;
	string body;
}

/// ditto
private Upload batchInputUpload(string filename, string content)
{
	enum boundary = "agent-batch-input-7f3c9a1e";
	enforce(!content.canFind(boundary), "batch input contains the multipart boundary " ~ boundary);
	enum delimiter = "--" ~ boundary ~ "\r\n";
	return Upload("multipart/form-data; boundary=" ~ boundary,
		delimiter ~ "Content-Disposition: form-data; name=\"purpose\"\r\n\r\nbatch\r\n"
		~ delimiter ~ "Content-Disposition: form-data; name=\"file\"; filename=\"" ~ filename ~ "\"\r\n"
		~ "Content-Type: application/jsonl\r\n\r\n" ~ content ~ "\r\n--" ~ boundary ~ "--\r\n");
}

/// The text of a Responses object: its `message` items' `output_text` parts joined, reasoning
/// items left out as the CLI leaves them out of its agent message.
private string responseText(const Json response)
{
	return messageParts(response, "output_text", "text");
}

/// The `field` of every `type` content part of a Responses object's `message` items, joined.
private string messageParts(const Json response, string type, string field)
{
	import std.algorithm : filter, joiner, map;
	import std.array : join;

	return response["output"].byValue
		.filter!(item => item["type"].get!string == "message")
		.map!(item => item["content"].byValue)
		.joiner
		.filter!(part => part["type"].get!string == type)
		.map!(part => part[field].get!string)
		.join;
}

/// The CLI's turn usage for a Responses object's `usage`.
private Json usage(const Json usage)
{
	return Json([
		"input_tokens": usage["input_tokens"],
		"cached_input_tokens": usage["input_tokens_details"]["cached_tokens"],
		"output_tokens": usage["output_tokens"],
		"reasoning_output_tokens": usage["output_tokens_details"]["reasoning_tokens"],
	]);
}

/// The statuses a batch ends in without a result.
private immutable endedStatuses = ["failed", "expired", "cancelled"];

/// Why a batch that ended in `status` failed: `batch <status>`, with the first of its
/// `errors` when it lists any.
private string batchFailure(string status, const Json errors)
{
	const failure = "batch " ~ status;
	const first = errors.type == Json.Type.object && errors["data"].length > 0 ? errors["data"][0] : Json.undefined;
	return first.type == Json.Type.object ? failure ~ ": " ~ first["message"].get!string : failure;
}


version (unittest)
{
	import agentcore.output.contract : enforceConsumerContract, enforceEventContract;
	import agentcore.output.terminal : Terminal, terminalFor;
	import fluent.asserts;
	import std.algorithm : map;
	import std.array : array;

	private BatchPoll succeededPoll()
	{
		return parsePoll(parseJsonString(import("batch/openai-batch-completed.json")),
			import("batch/openai-output-succeeded.json"));
	}
}

unittest // request with prompt "Say hello" and 1024 max tokens maps to one /v1/responses batch input line
{
	const request = BatchRequest("gpt-5-mini", "Say hello", Json.undefined, 1024, "agent-7c1e");
	(requestLine(request) == parseJsonString(import("batch/openai-request.json"))).should.equal(true);
}

unittest // request with an object schema sends it as a strict json_schema text format named output
{
	const schema = parseJsonString(`{"type":"object","properties":{"ok":{"type":"boolean"}}}`);
	const request = BatchRequest("gpt-5-mini", "Check", schema, 1024, "agent-7c1e");

	(requestLine(request)["body"]["text"] == parseJsonString(`{"format":{"type":"json_schema","name":"output",
		"schema":{"type":"object","properties":{"ok":{"type":"boolean"}}},"strict":true}}`)).should.equal(true);
}

unittest // validating, in_progress, finalizing and cancelling batches poll as pending
{
	BatchState state(string status)
	{
		auto batch = parseJsonString(import("batch/openai-batch-in-progress.json"));
		batch["status"] = status;
		return parsePoll(batch, "").state;
	}

	[state("validating"), state("in_progress"), state("finalizing"), state("cancelling")]
		.should.equal([BatchState.pending, BatchState.pending, BatchState.pending, BatchState.pending]);
}

unittest // completed batch with a 200 output line polls as succeeded carrying its Responses object
{
	const line = import("batch/openai-output-succeeded.json");
	const poll = parsePoll(parseJsonString(import("batch/openai-batch-completed.json")), line);
	[Json(poll.state == BatchState.succeeded), poll.result].should.equal([Json(true),
		parseJsonString(line)["response"]["body"]]);
}

unittest // completed batch whose error file line answered 400 polls as failed with the response's error message
{
	auto batch = parseJsonString(import("batch/openai-batch-completed.json"));
	batch["output_file_id"] = null;
	batch["error_file_id"] = "file-2Lr7nP4kWs8FxM1qC6tY3e";
	parsePoll(batch, import("batch/openai-output-errored.json")).should.equal(BatchPoll(BatchState.failed,
		Json.undefined, "Invalid schema for response_format 'output': In context=(), 'required' is required"
		~ " to be supplied and to be an array including every key in properties. Missing 'ok'."));
}

unittest // completed batch whose error file line has no response polls as failed with the line's error message
{
	const line = `{"id":"batch_req_1","custom_id":"agent-7c1e","response":null,"error":{"code":"batch_expired",`
		~ `"message":"This request could not be executed before the completion window expired."}}`;
	parsePoll(parseJsonString(import("batch/openai-batch-completed.json")), line).should.equal(BatchPoll(
		BatchState.failed, Json.undefined, "This request could not be executed before the completion window expired."));
}

unittest // failed batch polls as failed with "batch failed" and its first validation error message
{
	parsePoll(parseJsonString(import("batch/openai-batch-failed.json")), "").should.equal(BatchPoll(BatchState.failed,
		Json.undefined, "batch failed: The provided model 'gpt-5-mini-typo' is not supported by the Batch API."));
}

unittest // expired and cancelled batches without errors poll as failed "batch expired" and "batch cancelled"
{
	string failure(string status)
	{
		auto batch = parseJsonString(import("batch/openai-batch-in-progress.json"));
		batch["status"] = status;
		return parsePoll(batch, "").error;
	}

	[failure("expired"), failure("cancelled")].should.equal(["batch expired", "batch cancelled"]);
}

unittest // completed batch whose response is incomplete at max_output_tokens polls as failed naming the reason as codex does
{
	auto line = parseJsonString(import("batch/openai-output-succeeded.json"));
	line["response"]["body"]["status"] = "incomplete";
	line["response"]["body"]["incomplete_details"] = parseJsonString(`{"reason":"max_output_tokens"}`);
	parsePoll(parseJsonString(import("batch/openai-batch-completed.json")), line.toString).should.equal(BatchPoll(
		BatchState.failed, Json.undefined, "Incomplete response returned, reason: max_output_tokens"));
}

unittest // completed batch whose 200 response has status failed polls as failed with the response's error message
{
	auto line = parseJsonString(import("batch/openai-output-succeeded.json"));
	line["response"]["body"]["status"] = "failed";
	line["response"]["body"]["error"] = parseJsonString(`{"code":"server_error","message":"The model failed to respond."}`);
	parsePoll(parseJsonString(import("batch/openai-batch-completed.json")), line.toString)
		.should.equal(BatchPoll(BatchState.failed, Json.undefined, "The model failed to respond."));
}

unittest // completed batch whose message holds only a refusal translates to error and turn.failed lines carrying the refusal text
{
	auto line = parseJsonString(import("batch/openai-output-succeeded.json"));
	line["response"]["body"]["output"][1]["content"] = parseJsonString(
		`[{"type":"refusal","refusal":"I can't help with that."}]`);
	const poll = parsePoll(parseJsonString(import("batch/openai-batch-completed.json")), line.toString);

	(toCliEvents(poll, "t1")[2 .. $].map!parseJsonString.array == [
		`{"type":"error","message":"I can't help with that."}`,
		`{"type":"turn.failed","error":{"message":"I can't help with that."}}`,
	].map!parseJsonString.array).should.equal(true);
}

unittest // succeeded batch poll translates to codex events that pass both contracts with terminal ok
{
	const lines = toCliEvents(succeededPoll, "01a13b9c-2f41-7d30-b8e5-4c19a0d27e6b");
	({
		enforceEventContract("codex", lines);
		enforceConsumerContract("codex", lines);
	}).should.not.throwAnyException;
	terminalFor("codex", lines[$ - 1]).should.equal(Terminal(true, true));
}

unittest // succeeded batch poll with a reasoning item and an "ok" message translates to the agent_message ok and its usage
{
	(toCliEvents(succeededPoll, "t1").map!parseJsonString.array == [
		`{"type":"thread.started","thread_id":"t1"}`,
		`{"type":"turn.started"}`,
		`{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}`,
		`{"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":0,"output_tokens":75,`
			~ `"reasoning_output_tokens":64}}`,
	].map!parseJsonString.array).should.equal(true);
}

unittest // failed batch poll translates to an error line and turn.failed carrying the message that pass both contracts
{
	const lines = toCliEvents(parsePoll(parseJsonString(import("batch/openai-batch-failed.json")), ""), "t1");
	({
		enforceEventContract("codex", lines);
		enforceConsumerContract("codex", lines);
	}).should.not.throwAnyException;
	const message = "batch failed: The provided model 'gpt-5-mini-typo' is not supported by the Batch API.";
	(lines[2 .. $].map!parseJsonString.array == [Json(["type": Json("error"), "message": Json(message)]),
		Json(["type": Json("turn.failed"), "error": Json(["message": Json(message)])])]).should.equal(true);
}

unittest // succeeded and failed batch translations emit no top-level key the recorded codex cli streams lack for that event type
{
	import agentcore.output.contract : keysAbsentFrom;
	import std.string : splitLines;

	const recorded = import("events/codex-cli.jsonl").splitLines ~ import("events/codex-cli-error.jsonl").splitLines;
	const failed = toCliEvents(parsePoll(parseJsonString(import("batch/openai-batch-failed.json")), ""), "t1");
	keysAbsentFrom(recorded, toCliEvents(succeededPoll, "t1") ~ failed).should.equal(new string[][8]);
}

version (unittest)
{
	import agentcore.batch.provider : FakeTransport, HttpRequest, HttpResponse;

	private enum jsonHeaders = ["authorization": "Bearer sk-test", "content-type": "application/json"];
	private enum batchId = "batch_68ee4b1c2d3e8190a7f1c9e2b4d6a801";
}

unittest // submit uploads the request line as a batch purpose jsonl file then creates a 24h /v1/responses batch over it and returns the batch id
{
	auto transport = FakeTransport([HttpResponse(200, `{"id":"file-4Vq8rT2mXy9KpL3nB7wE1s","object":"file",`
			~ `"purpose":"batch","filename":"agent-7c1e.jsonl"}`),
		HttpResponse(200, import("batch/openai-batch-in-progress.json"))]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);
	const request = BatchRequest("gpt-5-mini", "Say hello", Json.undefined, 1024, "agent-7c1e");

	provider.submit(request).should.equal(batchId);
	enum boundary = "agent-batch-input-7f3c9a1e";
	transport.requests.should.equal([
		HttpRequest("POST", "https://api.openai.com/v1/files", [
			"authorization": "Bearer sk-test", "content-type": "multipart/form-data; boundary=" ~ boundary
		], "--" ~ boundary ~ "\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\nbatch\r\n"
			~ "--" ~ boundary ~ "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"agent-7c1e.jsonl\"\r\n"
			~ "Content-Type: application/jsonl\r\n\r\n" ~ requestLine(request).toString ~ "\n\r\n"
			~ "--" ~ boundary ~ "--\r\n"),
		HttpRequest("POST", "https://api.openai.com/v1/batches", jsonHeaders, Json([
			"input_file_id": Json("file-4Vq8rT2mXy9KpL3nB7wE1s"),
			"endpoint": Json("/v1/responses"),
			"completion_window": Json("24h"),
		]).toString),
	]);
}

unittest // poll of a completed batch GETs it then its output file content and reports the succeeded response
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/openai-batch-completed.json")),
		HttpResponse(200, import("batch/openai-output-succeeded.json"))]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.poll(batchId).should.equal(succeededPoll);
	transport.requests.should.equal([
		HttpRequest("GET", "https://api.openai.com/v1/batches/" ~ batchId, jsonHeaders, ""),
		HttpRequest("GET", "https://api.openai.com/v1/files/file-9Hc2dQ6wZr4TyN8mJ1vX5a/content", jsonHeaders, ""),
	]);
}

unittest // poll of an in_progress batch GETs only the batch and reports pending
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/openai-batch-in-progress.json"))]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	[Json(provider.poll(batchId).state == BatchState.pending), Json(transport.requests.length)]
		.should.equal([Json(true), Json(1)]);
}

unittest // poll of a completed batch with neither an output nor an error file reports failed "batch completed without a result"
{
	auto batch = parseJsonString(import("batch/openai-batch-completed.json"));
	batch["output_file_id"] = null;
	auto transport = FakeTransport([HttpResponse(200, batch.toString)]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.poll(batchId).should.equal(BatchPoll(BatchState.failed, Json.undefined,
		"batch completed without a result"));
}

unittest // poll of a completed batch whose only output file is empty reports failed "batch completed without a result"
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/openai-batch-completed.json")),
		HttpResponse(200, "")]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.poll(batchId).should.equal(BatchPoll(BatchState.failed, Json.undefined,
		"batch completed without a result"));
}

unittest // poll of a completed batch with an empty output file GETs its error file and reports the 400 line it holds
{
	auto batch = parseJsonString(import("batch/openai-batch-completed.json"));
	batch["error_file_id"] = "file-2Lr7nP4kWs8FxM1qC6tY3e";
	auto transport = FakeTransport([HttpResponse(200, batch.toString), HttpResponse(200, ""),
		HttpResponse(200, import("batch/openai-output-errored.json"))]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.poll(batchId).should.equal(parsePoll(batch, import("batch/openai-output-errored.json")));
	transport.requests[$ - 1].should.equal(HttpRequest("GET",
		"https://api.openai.com/v1/files/file-2Lr7nP4kWs8FxM1qC6tY3e/content", jsonHeaders, ""));
}

unittest // cancel POSTs to batches/batch_68ee4b1c2d3e8190a7f1c9e2b4d6a801/cancel
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/openai-batch-in-progress.json"))]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.cancel(batchId);

	transport.requests.should.equal([
		HttpRequest("POST", "https://api.openai.com/v1/batches/" ~ batchId ~ "/cancel", jsonHeaders, "")
	]);
}

unittest // cleanup of a completed batch GETs it then DELETEs its input and output files
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/openai-batch-completed.json")),
		HttpResponse(200, "{}"), HttpResponse(200, "{}")]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.cleanup(batchId);

	transport.requests.should.equal([
		HttpRequest("GET", "https://api.openai.com/v1/batches/" ~ batchId, jsonHeaders, ""),
		HttpRequest("DELETE", "https://api.openai.com/v1/files/file-4Vq8rT2mXy9KpL3nB7wE1s", jsonHeaders, ""),
		HttpRequest("DELETE", "https://api.openai.com/v1/files/file-9Hc2dQ6wZr4TyN8mJ1vX5a", jsonHeaders, ""),
	]);
}

unittest // cleanup of a failed batch with no output or error file DELETEs only its input file
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/openai-batch-failed.json")),
		HttpResponse(200, "{}")]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.cleanup(batchId);

	transport.requests[1 .. $].should.equal([
		HttpRequest("DELETE", "https://api.openai.com/v1/files/file-4Vq8rT2mXy9KpL3nB7wE1s", jsonHeaders, ""),
	]);
}

unittest // cleanup of a cancelling batch throws BatchNotSettled without DELETEing a file
{
	import agentcore.batch.provider : BatchNotSettled;

	auto batch = parseJsonString(import("batch/openai-batch-in-progress.json"));
	batch["status"] = "cancelling";
	auto transport = FakeTransport([HttpResponse(200, batch.toString)]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.cleanup(batchId).should.throwException!BatchNotSettled;
	transport.requests.length.should.equal(1);
}

unittest // cleanup whose input file DELETE answers 404 still DELETEs the output file without throwing
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/openai-batch-completed.json")),
		HttpResponse(404, `{"error":{"code":"not_found"}}`), HttpResponse(200, "{}")]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.cleanup(batchId).should.not.throwAnyException;
	transport.requests[$ - 1].should.equal(
		HttpRequest("DELETE", "https://api.openai.com/v1/files/file-9Hc2dQ6wZr4TyN8mJ1vX5a", jsonHeaders, ""));
}

unittest // cleanup whose input file DELETE answers 500 still DELETEs the output file, then throws naming the 500
{
	auto transport = FakeTransport([HttpResponse(200, import("batch/openai-batch-completed.json")),
		HttpResponse(500, `{"error":{"code":"server_error"}}`), HttpResponse(200, "{}")]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.cleanup(batchId).should.throwException!Exception.withMessage(
		`openai DELETE https://api.openai.com/v1/files/file-4Vq8rT2mXy9KpL3nB7wE1s: HTTP 500: {"error":{"code":"server_error"}}`);
	transport.requests.length.should.equal(3);
}

unittest // submit whose file upload is answered 429 throws naming the status and the error body
{
	auto transport = FakeTransport([HttpResponse(429, `{"error":{"code":"rate_limit_exceeded"}}`)]);
	auto provider = new OpenAIBatchProvider("sk-test", &transport.send);

	provider.submit(BatchRequest("gpt-5-mini", "Say hello", Json.undefined, 1024, "agent-7c1e"))
		.should.throwException!Exception.withMessage(
			`openai POST https://api.openai.com/v1/files: HTTP 429: {"error":{"code":"rate_limit_exceeded"}}`);
}
