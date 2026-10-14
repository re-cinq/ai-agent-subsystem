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

/// Builds the `BatchProvider` for a vendor, authenticated with `apiKey`; injected into the
/// reconcile driver so tests hand out a fake.
alias BatchProviderFor = BatchProvider delegate(Vendor vendor, string apiKey);

/// Finalizer holding a batch Agent's deletion until its provider-side batch is cancelled and cleaned up.
enum batchCleanupFinalizer = "agents.re-cinq.com/batch-cleanup";

/// Failed cleanups after which the finalizer is released anyway, leaving the provider object behind.
enum int maxBatchCleanupAttempts = 5;

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
