module agentcore.vendors.gemini.experiments;

/// gemini-cli's experiment flag for the default request timeout, in SECONDS
/// (`ExperimentFlags.DEFAULT_REQUEST_TIMEOUT`).
enum geminiRequestTimeoutFlagId = 45_773_134;

/// How long a Gemini request may wait for the first response byte. gemini-cli's own
/// limit is 60 s, and a thinking model on a large context routinely takes longer to
/// start answering: the request then fails with `fetch failed` and the CLI resends the
/// same context after a backoff, so a run stalls for minutes. 600 s leaves a slow
/// model room while still noticing a connection that is truly dead.
enum geminiRequestTimeoutSeconds = 600;

/// The document `GEMINI_EXP` points gemini-cli at: a local experiments file, read
/// before any experiments server is asked (API-key auth has none). `intValue` is a
/// string, the shape the CLI's experiment protocol uses.
string geminiExperimentsJson() @safe
{
	import std.conv : to;
	import std.format : format;

	return format(`{"flags":[{"flagId":%s,"intValue":"%s"}]}`,
		geminiRequestTimeoutFlagId, geminiRequestTimeoutSeconds.to!string);
}

version (unittest) import fluent.asserts;

@safe unittest
{
	geminiExperimentsJson.should.equal(`{"flags":[{"flagId":45773134,"intValue":"600"}]}`);
}
