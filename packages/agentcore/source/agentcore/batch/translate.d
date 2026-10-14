module agentcore.batch.translate;

import std.exception : enforce;

import agentcore.batch.anthropic : AnthropicBatchProvider, anthropicCliEvents = toCliEvents;
import agentcore.batch.provider : BatchPoll, BatchProvider, BatchProviderFor, HttpTransport;
import agentcore.core.vendor : Vendor;

/// The CLI event lines `vendor`'s harness would have printed for the run `poll` reports,
/// so a batch run's `status.output` reads the same as a Job run's.
string[] batchCliEvents(Vendor vendor, const BatchPoll poll, string sessionId)
{
	enforce(vendor == Vendor.claude, "batch output translation is not implemented for this vendor");
	return anthropicCliEvents(poll, sessionId);
}

/// The production `BatchProviderFor`: each vendor's batch API over `transport`. Only Anthropic
/// is implemented; the validation in `batchViolation` keeps other vendors from reaching here.
BatchProviderFor batchProvidersOver(HttpTransport transport)
{
	return (Vendor vendor, string apiKey) {
		import std.conv : to;

		enforce(vendor == Vendor.claude, "batch execution for " ~ vendor.to!string ~ " is not yet supported");
		return cast(BatchProvider) new AnthropicBatchProvider(apiKey, transport);
	};
}

version (unittest) import fluent.asserts;

unittest // claude routes to the anthropic provider while codex and gemini throw not yet supported
{
	import agentcore.batch.anthropic : AnthropicBatchProvider;
	import agentcore.batch.provider : HttpRequest, HttpResponse;

	auto providers = batchProvidersOver((HttpRequest request) => HttpResponse(200, "{}"));

	(cast(AnthropicBatchProvider) providers(Vendor.claude, "sk-ant-test") !is null).should.equal(true);
	providers(Vendor.codex, "sk").should.throwException!Exception
		.withMessage("batch execution for codex is not yet supported");
	providers(Vendor.gemini, "sk").should.throwException!Exception
		.withMessage("batch execution for gemini is not yet supported");
}
