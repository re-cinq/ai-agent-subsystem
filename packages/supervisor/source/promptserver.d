module promptserver;

import core.time : MonoTime;

import vibe.data.json : Json, parseJsonString;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPListener, HTTPServerRequest, HTTPServerResponse, HTTPServerSettings, listenHTTP;
import vibe.stream.operations : readAllUTF8;

import agentcore.core.env : maxRealtimePromptBytes;
import agentcore.core.token : bearerOf, tokenMatches;
import turnqueue : TurnQueue;

version (unittest) import fluent.asserts;

/// The state a realtime session shares between its prompt server and its turn loop.
final class RealtimeSession
{
	TurnQueue queue;
	string token; /// the bearer every request but the health check must present
	string sessionId; /// the agent's session id, once known
	bool closing; /// a close was requested: no new prompts, and the session ends once drained
	bool ending; /// the session is shutting down
	MonoTime lastActivity; /// when the last turn ended, or the session started

	this(string token)
	{
		this.token = token;
		lastActivity = MonoTime.currTime;
	}
}

/// An HTTP answer: its status and JSON body.
struct Reply
{
	int status;
	string body;
}

/// The answer to `method path` carrying `authorization` and `body_`, applied to `session`.
///
/// - `POST /v1/prompt` with `{"prompt":"…"}` queues a turn: 202 `{"turn","queued","sessionId"}`.
/// - `POST /v1/close` stops taking prompts and ends the session once the queued turns ran: 202.
/// - `GET /healthz` answers 200 without a token.
Reply route(HTTPMethod method, string path, string authorization, lazy string body_, RealtimeSession session)
{
	if (method == HTTPMethod.GET && path == "/healthz")
		return Reply(200, `{"status":"ok"}`);
	if (method != HTTPMethod.POST || (path != "/v1/prompt" && path != "/v1/close"))
		return failure(404, "not found");
	if (!tokenMatches(bearerOf(authorization), session.token))
		return failure(401, "missing or wrong bearer token");
	if (session.closing || session.ending)
		return failure(409, "the session is ending");
	if (path == "/v1/close")
		return close(session);
	return prompt(body_, session);
}

private Reply close(RealtimeSession session)
{
	session.closing = true;
	return Reply(202, Json(["queued": Json(session.queue.queued)]).toString());
}

private Reply prompt(string body_, RealtimeSession session)
{
	const text = promptOf(body_);
	if (text.length > maxRealtimePromptBytes)
		return failure(413, "prompt exceeds " ~ maxRealtimePromptBytes.stringOf ~ " bytes");
	if (text.length == 0)
		return failure(400, `body must be JSON with a non-empty "prompt" string`);
	const turn = session.queue.push(text);
	if (turn == 0)
		return failure(429, "too many queued prompts");
	return Reply(202, Json(["turn": Json(turn), "queued": Json(session.queue.queued),
		"sessionId": Json(session.sessionId)]).toString());
}

/// The `prompt` string of a JSON request body, or "" when there is none.
private string promptOf(string body_) nothrow
{
	try
	{
		auto request = parseJsonString(body_);
		if (request.type != Json.Type.object || "prompt" !in request || request["prompt"].type != Json.Type.string)
			return "";
		return request["prompt"].get!string;
	}
	catch (Exception)
		return "";
}

private Reply failure(int status, string message)
{
	return Reply(status, Json(["error": Json(message)]).toString());
}

private string stringOf(size_t value)
{
	import std.conv : to;

	return value.to!string;
}

/// Serve `session`'s routes on `port`, on every interface (the controller reaches the pod IP).
HTTPListener listenPrompts(ushort port, RealtimeSession session)
{
	auto settings = new HTTPServerSettings;
	settings.port = port;
	settings.bindAddresses = ["0.0.0.0", "::"];
	// JSON escaping can double a prompt's bytes; anything larger is refused before it is read.
	settings.maxRequestSize = 2 * maxRealtimePromptBytes + 4096;
	return listenHTTP(settings, (scope HTTPServerRequest req, scope HTTPServerResponse res) @trusted {
		const reply = route(req.method, req.requestPath.toString, req.headers.get("Authorization", ""),
			req.bodyReader.readAllUTF8(), session);
		res.writeBody(reply.body, reply.status, "application/json");
	});
}

version (unittest)
{
	private Reply post(RealtimeSession session, string path, string body_, string authorization = "Bearer t-1")
	{
		return route(HTTPMethod.POST, path, authorization, body_, session);
	}
}

unittest // a prompt with the run's token is queued as turn 1 and reports the session id
{
	auto session = new RealtimeSession("t-1");
	session.sessionId = "sess-1";

	const reply = post(session, "/v1/prompt", `{"prompt":"hello"}`);

	[reply.status == 202, parseJsonString(reply.body) == parseJsonString(`{"turn":1,"queued":1,"sessionId":"sess-1"}`)]
		.should.equal([true, true]);
}

unittest // a request without the run's token is refused 401 and queues nothing
{
	auto session = new RealtimeSession("t-1");

	[post(session, "/v1/prompt", `{"prompt":"hi"}`, "").status,
		post(session, "/v1/prompt", `{"prompt":"hi"}`, "Bearer t-2").status,
		post(session, "/v1/close", "", "Bearer t-2").status].should.equal([401, 401, 401]);
	[session.queue.queued, session.closing].should.equal([0, false]);
}

unittest // a body without a non-empty prompt string is refused 400
{
	auto session = new RealtimeSession("t-1");

	[post(session, "/v1/prompt", "not json").status, post(session, "/v1/prompt", `{"prompt":""}`).status,
		post(session, "/v1/prompt", `{"prompt":3}`).status, post(session, "/v1/prompt", `["hi"]`).status]
		.should.equal([400, 400, 400, 400]);
}

unittest // a prompt over the size limit is refused 413
{
	import std.array : replicate;

	auto session = new RealtimeSession("t-1");
	const big = "x".replicate(maxRealtimePromptBytes + 1);

	post(session, "/v1/prompt", `{"prompt":"` ~ big ~ `"}`).status.should.equal(413);
}

unittest // a prompt past the queue limit is refused 429
{
	import agentcore.core.env : maxQueuedTurns;

	auto session = new RealtimeSession("t-1");
	foreach (i; 0 .. maxQueuedTurns)
		post(session, "/v1/prompt", `{"prompt":"p"}`);

	post(session, "/v1/prompt", `{"prompt":"p"}`).status.should.equal(429);
}

unittest // close marks the session closing and later prompts and closes are refused 409
{
	auto session = new RealtimeSession("t-1");
	post(session, "/v1/prompt", `{"prompt":"p"}`);

	const closed = post(session, "/v1/close", "");

	[closed.status, post(session, "/v1/prompt", `{"prompt":"p"}`).status, post(session, "/v1/close", "").status]
		.should.equal([202, 409, 409]);
	[closed.body == `{"queued":1}`, session.closing].should.equal([true, true]);
}

unittest // the health check needs no token, and unknown routes are 404
{
	auto session = new RealtimeSession("t-1");

	[route(HTTPMethod.GET, "/healthz", "", "", session).status, route(HTTPMethod.GET, "/v1/prompt", "", "", session)
		.status, post(session, "/v1/other", "").status].should.equal([200, 404, 404]);
}
