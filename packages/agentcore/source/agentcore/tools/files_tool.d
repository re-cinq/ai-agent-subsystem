module agentcore.tools.files_tool;

import std.conv : to;
import vibe.data.json : Json, parseJsonString;

import agentcore.core.env : envFileHeadersPrefix;
import agentcore.crds.input_file : InputFile;
import agentcore.crds.serialization : fromJson;
import agentcore.output.fileevent : resolveWatchedPath;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.tool : Tool;

/// Parse the JSON array of input files the controller serialized into `AGENT_FILES` —
/// the CRD struct itself, so no field is dropped at this seam. An entry missing `path`
/// or `url` is skipped (the controller never emits one); a malformed document yields
/// an empty list rather than throwing.
InputFile[] parseInputFiles(string json)
{
	if (json.length == 0)
		return null;

	InputFile[] files;
	try
	{
		foreach (entry; parseJsonString(json).get!(Json[]))
			if ("path" in entry && "url" in entry)
			{
				const file = fromJson!InputFile(entry);
				if (file.path.length && file.url.length)
					files ~= file;
			}
	}
	catch (Exception)
		return null;
	return files;
}

/// The shell-safe variable the init exports file `index`'s resolved header block under.
string fileHeadersEnv(size_t index) @safe pure
{
	return envFileHeadersPrefix ~ index.to!string;
}

/// The download script. Every value rides a positional argument — `$1` the resolved
/// destination, `$2` the url, `$3` the workspace — so nothing from the Agent is ever
/// spliced into shell text. The lexical check (resolveWatchedPath) has already kept
/// the path inside the workspace; this repeats it on the PHYSICAL path, because the
/// init runs as root after the clones, and a cloned repo can carry a symlink that
/// would otherwise carry the write out of the workspace. The file's contents stream
/// from curl straight to disk and never touch an argv.
private string downloadScript(string headerVar) @safe pure
{
	// The header block goes to curl on stdin (`-H @-`), one header per line, so a
	// multi-line block works and the credential never appears in curl's argv.
	const curl = headerVar.length
		? "printf '%s\\n' \"$" ~ headerVar ~ "\" | curl -fsSL --proto =http,https -H @- -o \"$1\" \"$2\""
		: "curl -fsSL --proto =http,https -o \"$1\" \"$2\"";
	return `mkdir -p "$3" "$(dirname "$1")" && root=$(cd "$3" && pwd -P)`
		~ ` && dir=$(cd "$(dirname "$1")" && pwd -P) || exit 1; `
		~ `case "$dir/" in "$root"/*) ;; *) echo "[init] input file $1 resolves outside the workspace" >&2; exit 1;; esac; `
		~ `if [ -L "$1" ]; then echo "[init] input file $1 is a symlink; refusing to write through it" >&2; exit 1; fi; `
		~ curl ~ ` || { echo "[init] input file $1: download failed" >&2; exit 1; }`;
}

/// A step that fails the init, naming the offending path.
private string[] refusal(string message, string path) @safe pure
{
	return ["sh", "-c", `echo "[init] input file $1: ` ~ message ~ `" >&2; exit 1`, "sh", path];
}

/// Download the run's input files into the workspace before the agent starts.
///
/// Runs after the clones, because a clone `rm -rf`s its destination and would take a
/// file placed under it along; and before the init hands the workspace to the agent
/// uid, so the files end up the agent's to read and edit. A file the run declared is
/// one its prompt expects, so unlike a conversation restore this is NOT best-effort:
/// a refused path or a failed download fails the init, naming the path.
final class FilesTool : Tool
{
	override string name() const @safe
	{
		return "files";
	}

	override string[] requires() const @safe
	{
		return ["sh", "curl"];
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		string[][] result;
		foreach (i, file; ctx.files)
		{
			const dest = resolveWatchedPath(file.path, ctx.workspaceDir);
			if (dest.isNull)
			{
				result ~= refusal("path escapes the workspace", file.path);
				continue;
			}
			const headerVar = file.headersSecret.length ? fileHeadersEnv(i) : "";
			result ~= [
				"sh", "-c", downloadScript(headerVar), "sh", dest.get, file.url,
				ctx.workspaceDir,
			];
		}
		return result;
	}
}

version (unittest) import fluent.asserts;

unittest
{
	// The controller's array round-trips; incomplete entries and bad JSON yield nothing.
	parseInputFiles(`[{"path":"notes/brief.md","url":"https://files.example/b","headers_secret":"auth"}]`)
		.should.equal([InputFile("notes/brief.md", "https://files.example/b", "auth")]);
	parseInputFiles(`[{"path":"a"},{"url":"b"},{"path":"","url":"c"}]`).length.should.equal(0);
	parseInputFiles("not json").length.should.equal(0);
	parseInputFiles("").length.should.equal(0);
}

@safe unittest
{
	// No files declared: no step at all.
	InitContext ctx;
	(new FilesTool).steps(ctx).length.should.equal(0);
}

@safe unittest
{
	// Each file is one step whose path, url and workspace ride positional arguments,
	// never the script text.
	InitContext ctx;
	ctx.workspaceDir = "/workspace";
	ctx.files = [InputFile("notes/brief.md", "https://files.example/brief.md")];

	const steps = (new FilesTool).steps(ctx);

	steps.length.should.equal(1);
	steps[0][0 .. 2].should.equal(["sh", "-c"]);
	steps[0][3 .. $].should.equal(
		["sh", "/workspace/notes/brief.md", "https://files.example/brief.md", "/workspace"]);
	steps[0][2].should.contain(`curl -fsSL --proto =http,https -o "$1" "$2"`);
	steps[0][2].should.not.contain("files.example");
	steps[0][2].should.not.contain("brief.md");
	steps[0][2].should.not.contain("-H");
}

@safe unittest
{
	// A configured header reaches curl on stdin through the shell-safe variable the
	// init exports, never the secret key's own (possibly dashed) name.
	InitContext ctx;
	ctx.workspaceDir = "/workspace";
	ctx.files = [
		InputFile("a.md", "https://files.example/a"),
		InputFile("b.md", "https://files.example/b", "files-auth"),
	];

	const steps = (new FilesTool).steps(ctx);

	steps[1][2].should.contain(`printf '%s\n' "$AGENT_FILE_HEADERS_1" | curl`);
	steps[1][2].should.contain("-H @-");
	steps[1][2].should.not.contain("files-auth");
}

@safe unittest
{
	// A path escaping the workspace becomes a step that fails the init, naming it.
	InitContext ctx;
	ctx.workspaceDir = "/workspace";
	ctx.files = [InputFile("../etc/passwd", "https://files.example/x")];

	const steps = (new FilesTool).steps(ctx);

	steps.length.should.equal(1);
	steps[0][2].should.contain("path escapes the workspace");
	steps[0][2].should.contain("exit 1");
	steps[0][$ - 1].should.equal("../etc/passwd");
}
