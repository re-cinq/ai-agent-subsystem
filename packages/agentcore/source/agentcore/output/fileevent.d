module agentcore.output.fileevent;

import vibe.data.json : Json, parseJsonString;
import std.file : exists, isFile, getSize, read;
import std.path : buildNormalizedPath, isAbsolute;
import std.typecons : Nullable, nullable;

import agentcore.crds.output_watch : OutputWatch;
import agentcore.crds.serialization : fromJson;

version (unittest) import fluent.asserts;

/// Discriminator stamped on every file event, beside `lifecycle`, so a consumer can
/// tell a produced artifact apart from raw agent output and from lifecycle notices.
enum fileKind = "file";

/// Cap on the bytes read from a watched file. The content rides stdout into
/// `status.output`, which the controller already caps (MAX_OUTPUT_BYTES, 256 KiB) —
/// a larger artifact would be truncated there anyway, mid-JSON and without saying
/// so. Refusing it here means the consumer gets a clean "too large" signal instead
/// of a silently corrupted payload.
enum maxWatchedFileBytes = 128 * 1024;

/// A produced artifact, serialized as the inner `event` payload of the shared
/// envelope so it looks like every other notification on the stream.
struct FileEvent
{
	string event; /// the recipe-declared event name
	string path; /// the resolved path the content was read from
	string content; /// the file's contents, empty when `reason` is set
	string reason; /// optional: why there is no content ("missing", "too-large", "unreadable")
}

/// The compact JSON line for the envelope's `event`. Never throws — it is emitted
/// from nothrow paths.
string toJson(in FileEvent e) nothrow
{
	try
	{
		Json[string] o;
		o["kind"] = Json(fileKind);
		o["event"] = Json(e.event);
		o["path"] = Json(e.path);
		if (e.reason.length)
			o["reason"] = Json(e.reason);
		else
			o["content"] = Json(e.content);
		return Json(o).toString();
	}
	catch (Exception)
		return `{"kind":"file","reason":"unreadable"}`;
}

/// Parse the JSON array of watches the controller serialized into `AGENT_WATCH` —
/// the same CRD struct, so no field can be dropped at this seam. An entry missing
/// `event` or `path` is skipped (the controller never emits one); a malformed
/// document yields an empty list rather than throwing.
OutputWatch[] parseWatches(string json)
{
	if (json.length == 0)
		return null;

	OutputWatch[] watches;
	try
	{
		foreach (entry; parseJsonString(json).get!(Json[]))
			if ("event" in entry && "path" in entry)
			{
				const w = fromJson!OutputWatch(entry);
				if (w.event.length && w.path.length)
					watches ~= w;
			}
	}
	catch (Exception)
		return null;
	return watches;
}

/// Resolve a watch's path against the workspace, refusing anything that escapes it.
/// The agent container's cwd is `/`, so a relative path can only sensibly mean the
/// workspace; and a recipe must not be able to read arbitrary host paths out of the
/// pod, so an absolute path outside the workspace is rejected too (mirrors the
/// init's `safeDest`). Null when the path is not allowed.
Nullable!string resolveWatchedPath(string path, string workspaceDir) nothrow
{
	try
	{
		const root = buildNormalizedPath(workspaceDir.length ? workspaceDir : "/workspace");
		const full = buildNormalizedPath(path.isAbsolute ? path : root ~ "/" ~ path);

		// Strictly below the root: the root itself is a directory, never an artifact.
		if (full.length <= root.length + 1 || full[0 .. root.length] != root
			|| full[root.length] != '/')
			return Nullable!string.init;
		return nullable(full);
	}
	catch (Exception)
		return Nullable!string.init;
}

/// Read one watched artifact into an event. Always yields an event once the path is
/// allowed — a missing or oversized file reports `reason` rather than vanishing,
/// because "the agent produced nothing" is exactly the outcome a consumer needs to
/// hear about. Null only when the path itself is refused, which is a recipe bug the
/// run should not be judged on. Never throws.
Nullable!FileEvent readWatched(in OutputWatch watch, string workspaceDir) nothrow
{
	const resolved = resolveWatchedPath(watch.path, workspaceDir);
	if (resolved.isNull)
		return Nullable!FileEvent.init;

	const full = resolved.get;
	FileEvent e = {event: watch.event, path: full};
	try
	{
		if (!full.exists || !full.isFile)
		{
			e.reason = "missing";
			return nullable(e);
		}
		if (full.getSize > maxWatchedFileBytes)
		{
			e.reason = "too-large";
			return nullable(e);
		}
		e.content = cast(string) full.read();
	}
	catch (Exception)
		e.reason = "unreadable";
	return nullable(e);
}

unittest
{
	// the event carries its name, path and contents, tagged with the discriminator
	const json = FileEvent("planning.result", "/workspace/target/result.json", `{"a":1}`).toJson;
	json.should.contain(`"kind":"file"`);
	json.should.contain(`"event":"planning.result"`);
	json.should.contain(`"path":"/workspace/target/result.json"`);
	json.should.contain(`"content":"{\"a\":1}"`);
	json.should.not.contain(`"reason"`);
}

unittest
{
	// a reason replaces the content rather than sitting beside an empty one
	FileEvent e = {event: "planning.result", path: "/workspace/target/result.json"};
	e.reason = "missing";
	const json = e.toJson;
	json.should.contain(`"reason":"missing"`);
	json.should.not.contain(`"content"`);
}

unittest
{
	// the controller's array round-trips, including both required fields
	const watches = parseWatches(
		`[{"event":"planning.result","path":"result.json"}]`);
	watches.length.should.equal(1);
	watches[0].event.should.equal("planning.result");
	watches[0].path.should.equal("result.json");
}

unittest
{
	// incomplete entries are skipped and malformed input yields nothing, never a throw
	parseWatches(`[{"event":"x"},{"path":"y"},{"event":"","path":"z"}]`).length.should.equal(0);
	parseWatches("not json").length.should.equal(0);
	parseWatches("").length.should.equal(0);
}

unittest
{
	// relative paths resolve against the workspace; the workspace root itself is not
	// an artifact, and traversal out of it is refused
	resolveWatchedPath("result.json", "/workspace").get.should.equal("/workspace/result.json");
	resolveWatchedPath("target/result.json", "/workspace").get
		.should.equal("/workspace/target/result.json");
	resolveWatchedPath("/workspace/target/result.json", "/workspace").get
		.should.equal("/workspace/target/result.json");
	resolveWatchedPath("../etc/passwd", "/workspace").isNull.should.equal(true);
	resolveWatchedPath("/etc/passwd", "/workspace").isNull.should.equal(true);
	resolveWatchedPath("/workspace", "/workspace").isNull.should.equal(true);
}

unittest
{
	import std.file : mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;

	const root = buildPath(".test-watch");
	// A nested function, not an inline try: D forbids `catch` in a scope-guard body.
	void tidy() nothrow
	{
		try
			rmdirRecurse(root);
		catch (Exception)
		{
		}
	}

	scope (exit)
		tidy();
	mkdirRecurse(buildPath(root, "target"));
	write(buildPath(root, "target", "result.json"), `{"ok":true}`);

	// a produced artifact reports its contents
	const found = readWatched(OutputWatch("planning.result", "target/result.json"), root);
	found.get.content.should.equal(`{"ok":true}`);
	found.get.reason.should.equal("");

	// an artifact the agent never wrote reports why, rather than vanishing
	const missing = readWatched(OutputWatch("planning.result", "target/absent.json"), root);
	missing.get.reason.should.equal("missing");
	missing.get.content.should.equal("");

	// a refused path yields no event at all
	readWatched(OutputWatch("planning.result", "../outside.json"), root).isNull
		.should.equal(true);
}
