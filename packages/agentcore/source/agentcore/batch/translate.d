module agentcore.batch.translate;

import std.exception : enforce;

import agentcore.batch.anthropic : AnthropicBatchProvider, anthropicCliEvents = toCliEvents;
import agentcore.batch.gemini : GeminiBatchProvider, geminiCliEvents = toCliEvents;
import agentcore.batch.provider : BatchPoll, BatchProvider, BatchProviderFor, HttpTransport;
import agentcore.core.vendor : Vendor;

/// The CLI event lines `vendor`'s harness would have printed for the run `poll` reports,
/// so a batch run's `status.output` reads the same as a Job run's.
string[] batchCliEvents(Vendor vendor, const BatchPoll poll, string sessionId)
{
	enforce(vendor == Vendor.claude || vendor == Vendor.gemini,
		"batch output translation is not implemented for this vendor");
	return vendor == Vendor.gemini ? geminiCliEvents(poll, sessionId) : anthropicCliEvents(poll, sessionId);
}

/// The production `BatchProviderFor`: each vendor's batch API over `transport`. Anthropic and
/// Gemini are implemented; the validation in `batchViolation` keeps other vendors from reaching here.
BatchProviderFor batchProvidersOver(HttpTransport transport)
{
	return (Vendor vendor, string apiKey) {
		import std.conv : to;

		enforce(vendor == Vendor.claude || vendor == Vendor.gemini,
			"batch execution for " ~ vendor.to!string ~ " is not yet supported");
		return vendor == Vendor.gemini ? cast(BatchProvider) new GeminiBatchProvider(apiKey, transport)
			: cast(BatchProvider) new AnthropicBatchProvider(apiKey, transport);
	};
}

version (unittest) import fluent.asserts;

unittest // claude and gemini route to their providers while codex throws not yet supported
{
	import agentcore.batch.anthropic : AnthropicBatchProvider;
	import agentcore.batch.gemini : GeminiBatchProvider;
	import agentcore.batch.provider : HttpRequest, HttpResponse;

	auto providers = batchProvidersOver((HttpRequest request) => HttpResponse(200, "{}"));

	[cast(AnthropicBatchProvider) providers(Vendor.claude, "sk-ant-test") !is null,
		cast(GeminiBatchProvider) providers(Vendor.gemini, "gm-test") !is null].should.equal([true, true]);
	providers(Vendor.codex, "sk").should.throwException!Exception
		.withMessage("batch execution for codex is not yet supported");
}

unittest // gemini batch poll translates to the gemini cli events
{
	import agentcore.batch.gemini : geminiCliEvents = toCliEvents, parsePoll;
	import vibe.data.json : parseJsonString;

	const poll = parsePoll(parseJsonString(import("batch/gemini-batch-succeeded.json")));
	batchCliEvents(Vendor.gemini, poll, "s1").should.equal(geminiCliEvents(poll, "s1"));
}
