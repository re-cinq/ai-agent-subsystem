module agentcore.batch.translate;

import std.exception : enforce;

import agentcore.batch.anthropic : AnthropicBatchProvider, anthropicCliEvents = toCliEvents;
import agentcore.batch.gemini : GeminiBatchProvider, geminiCliEvents = toCliEvents;
import agentcore.batch.openai : OpenAIBatchProvider, codexCliEvents = toCliEvents;
import agentcore.batch.provider : BatchPoll, BatchProvider, BatchProviderFor, HttpTransport;
import agentcore.core.vendor : Vendor;

/// The CLI event lines `vendor`'s harness would have printed for the run `poll` reports,
/// so a batch run's `status.output` reads the same as a Job run's.
string[] batchCliEvents(Vendor vendor, const BatchPoll poll, string sessionId)
{
	switch (vendor)
	{
	case Vendor.claude:
		return anthropicCliEvents(poll, sessionId);
	case Vendor.codex:
		return codexCliEvents(poll, sessionId);
	case Vendor.gemini:
		return geminiCliEvents(poll, sessionId);
	default:
		enforce(false, "batch output translation is not implemented for this vendor");
		assert(0);
	}
}

/// The production `BatchProviderFor`: each vendor's batch API over `transport`. Anthropic,
/// OpenAI and Gemini are implemented; the validation in `batchViolation` keeps other vendors
/// from reaching here.
BatchProviderFor batchProvidersOver(HttpTransport transport)
{
	return (Vendor vendor, string apiKey) {
		import std.conv : to;

		switch (vendor)
		{
		case Vendor.claude:
			return cast(BatchProvider) new AnthropicBatchProvider(apiKey, transport);
		case Vendor.codex:
			return cast(BatchProvider) new OpenAIBatchProvider(apiKey, transport);
		case Vendor.gemini:
			return cast(BatchProvider) new GeminiBatchProvider(apiKey, transport);
		default:
			enforce(false, "batch execution for " ~ vendor.to!string ~ " is not yet supported");
			assert(0);
		}
	};
}

version (unittest) import fluent.asserts;

unittest // claude, gemini and codex route to their providers while opencode throws not yet supported
{
	import agentcore.batch.anthropic : AnthropicBatchProvider;
	import agentcore.batch.gemini : GeminiBatchProvider;
	import agentcore.batch.openai : OpenAIBatchProvider;
	import agentcore.batch.provider : HttpRequest, HttpResponse;

	auto providers = batchProvidersOver((HttpRequest request) => HttpResponse(200, "{}"));

	[cast(AnthropicBatchProvider) providers(Vendor.claude, "sk-ant-test") !is null,
		cast(GeminiBatchProvider) providers(Vendor.gemini, "gm-test") !is null,
		cast(OpenAIBatchProvider) providers(Vendor.codex, "sk-test") !is null].should.equal([true, true, true]);
	providers(Vendor.opencode, "sk").should.throwException!Exception
		.withMessage("batch execution for opencode is not yet supported");
}

unittest // gemini batch poll translates to the gemini cli events
{
	import agentcore.batch.gemini : geminiCliEvents = toCliEvents, parsePoll;
	import vibe.data.json : parseJsonString;

	const poll = parsePoll(parseJsonString(import("batch/gemini-batch-succeeded.json")));
	batchCliEvents(Vendor.gemini, poll, "s1").should.equal(geminiCliEvents(poll, "s1"));
}

unittest // codex batch poll translates to the codex cli events
{
	import agentcore.batch.openai : codexCliEvents = toCliEvents, parsePoll;
	import vibe.data.json : parseJsonString;

	const poll = parsePoll(parseJsonString(import("batch/openai-batch-completed.json")),
		import("batch/openai-output-succeeded.json"));
	batchCliEvents(Vendor.codex, poll, "s1").should.equal(codexCliEvents(poll, "s1"));
}
