module agentcore.crds.watch_upload;

import agentcore.crds.schema;

/// Where a watched file is uploaded instead of riding the event stream inline.
///
/// A watch is declared on the recipe while its destination usually belongs to one
/// run, so `url` may carry the placeholders `{agent}` (the run's Agent name) and
/// `{event}` (the watch's event name), expanded when the file is uploaded.
struct WatchUpload
{
	/// The http(s) URL the file's bytes are POSTed to.
	@optional @Required @Description(
		"URL the file is POSTed to; {agent} and {event} are expanded per run.")
	string url;

	/// Names a key in the agent's secret holding a header block sent with the upload —
	/// the same convention sinks use.
	@optional @wire("headers_secret") @Description(
		"Secret key holding the header block sent with the upload.")
	string headersSecret;
}

@safe unittest
{
	static assert(jsonNameOf!(WatchUpload.headersSecret) == "headers_secret");
}
