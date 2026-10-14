module agentcore.batch.provider;

import vibe.data.json : Json;

import agentcore.core.vendor : Vendor;

/// One single-turn prompt submitted to a vendor's batch API.
struct BatchRequest
{
	string model;
	string prompt;
	Json schema;
	long maxTokens;
	string customId;
}

/// Whether `schema` (a request's `output.schema`) asks for structured output.
bool hasSchema(const Json schema)
{
	return schema.type != Json.Type.undefined && schema.type != Json.Type.null_;
}

enum BatchState
{
	pending,
	succeeded,
	failed,
}

/// A batch's state as of one poll; `result` holds the vendor's message on success.
struct BatchPoll
{
	BatchState state;
	Json result;
	string error;
}

/// A vendor's batch API: submit one request, poll it, cancel it, and delete what it left behind.
interface BatchProvider
{
	string submit(BatchRequest request);
	BatchPoll poll(string id);
	void cancel(string id);
	void cleanup(string id);
}

/// Thrown by `BatchProvider.cleanup` when the batch has not reached a terminal state yet (a
/// cancel still settling), so what it will leave behind cannot be deleted until a later try.
class BatchNotSettled : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
	{
		super(msg, file, line);
	}
}

/// One HTTPS call a batch provider makes, and its answer; providers send them through an
/// injected `HttpTransport` so they stay testable without a network.
struct HttpRequest
{
	string method;
	string url;
	string[string] headers;
	string body;
}

/// ditto
struct HttpResponse
{
	int status;
	string body;
}

/// ditto
alias HttpTransport = HttpResponse delegate(HttpRequest request);

version (unittest)
{
	/// Records each request and answers with the next scripted response.
	struct FakeTransport
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
}

/// Builds the `BatchProvider` for a vendor, authenticated with `apiKey`; injected into the
/// reconcile driver so tests hand out a fake.
alias BatchProviderFor = BatchProvider delegate(Vendor vendor, string apiKey);

/// Finalizer holding a batch Agent's deletion until its provider-side batch is cancelled and cleaned up.
enum batchCleanupFinalizer = "agents.re-cinq.com/batch-cleanup";

/// Failed cleanups after which the finalizer is released anyway, leaving the provider object behind.
enum int maxBatchCleanupAttempts = 5;

/// Minutes after a batch Agent's `startedAt` that a cleanup reporting `BatchNotSettled` keeps
/// its finalizer without counting a failed attempt. Every provider expires a batch 24 hours
/// after submission and a cancel settles within minutes, so a batch still unsettled at 48
/// hours is stuck; its cleanups then count toward `maxBatchCleanupAttempts`.
enum int batchSettleMinutes = 48 * 60;

/// The model a batch request names: the run's model, or `claude-opus-5-5` when it names none.
/// The CLI falls back to its own default model; a batch request must name one.
string batchModel(string model) @safe pure nothrow
{
	return model.length ? model : "claude-opus-5-5";
}

/// The batch API a vendor's models are submitted to, and the `resources.secrets` env name
/// that carries its API key — the same name the CLI harness reads.
struct BatchVendor
{
	string provider;
	string apiKeyEnv;
}

/// ditto
BatchVendor batchVendor(Vendor vendor) @safe pure
{
	import std.exception : enforce;

	final switch (vendor)
	{
	case Vendor.claude:
		return BatchVendor("anthropic", "ANTHROPIC_API_KEY");
	case Vendor.codex:
		return BatchVendor("openai", "OPENAI_API_KEY");
	case Vendor.gemini:
		return BatchVendor("gemini", "GEMINI_API_KEY");
	case Vendor.exec:
	case Vendor.opencode:
		enforce(false, "no batch API for vendor " ~ (vendor == Vendor.exec ? "exec" : "opencode"));
		assert(0);
	}
}

version (unittest) import fluent.asserts;

unittest // batch model of gemini-3.1-flash-lite stays gemini-3.1-flash-lite while an empty model becomes claude-opus-5-5
{
	[batchModel("gemini-3.1-flash-lite"), batchModel("")].should.equal(["gemini-3.1-flash-lite", "claude-opus-5-5"]);
}
