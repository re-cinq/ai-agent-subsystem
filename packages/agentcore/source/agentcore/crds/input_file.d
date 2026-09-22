module agentcore.crds.input_file;

import agentcore.crds.schema;

/// A file the init container downloads into the workspace before the agent starts.
///
/// Only the reference travels in the Agent: the bytes are fetched from `url` at pod
/// start, so a run's inputs can be as large as the source serves without ever
/// crossing etcd's per-object limit. What the file holds is the caller's business —
/// the subsystem only puts it where the recipe's prompt expects to find it.
struct InputFile
{
	/// Where the file lands. Relative paths resolve against WORKSPACE_DIR and must stay
	/// inside it; missing parent directories are created.
	@optional @Required @Description(
		"Destination, relative to WORKSPACE_DIR; must stay inside it.")
	string path;

	/// The http(s) URL the init streams the file from. The init fetches no other scheme,
	/// so a `file://` url can never copy a path of the init container into the workspace.
	@optional @Required @Pattern(`^https?://`) @Description(
		"http(s) URL the file is downloaded from.")
	string url;

	/// Names a key in the agent's secret holding a header block (`Name: value` lines)
	/// sent with the download — the same convention sinks and MCP servers use.
	@optional @wire("headers_secret") @Description(
		"Secret key holding the header block sent with the download.")
	string headersSecret;
}

@safe unittest
{
	static assert(jsonNameOf!(InputFile.headersSecret) == "headers_secret");
}
