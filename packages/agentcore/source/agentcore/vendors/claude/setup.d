module agentcore.vendors.claude.setup;

import std.algorithm.iteration : map;
import std.array : join;
import std.file : exists;

import agentcore.core.exec : findExecutable;
import agentcore.kube.bundle : claudeStageSource;
import agentcore.vendors.base.setup : AgentSetup, CliOrigin, CliReport;

/// The Claude Code CLI release a run installs: the one the agent image bakes, its
/// `CLAUDE_CLI_VERSION` build arg (a unit test holds the two equal).
enum claudeCliVersion = "2.1.311";

/// One architecture's native glibc build of `claudeCliVersion`; the hashes come from
/// downloads.claude.ai/claude-code-releases/<version>/manifest.json.
struct ClaudePackage
{
	string machine; /// what `uname -m` reports
	string platform; /// the release's directory for it
	string sha256;
}

immutable ClaudePackage[] claudePackages = [
	ClaudePackage("x86_64", "linux-x64", "86dc1fcc69498159eaf15f446613e847010f9036bfbbdffd4c49350be8489ada"),
	ClaudePackage("aarch64", "linux-arm64", "2e2496c9a8065df93acb0fca2d341f59a6b8777649b2e025ab8c9bcd5eef61f3"),
];

/// Put the Claude Code CLI on `~/.local/bin` in the shared HOME. The agent image
/// bakes a pinned CLI at `claudeStageSource`, so the init copies that — no network,
/// and every run of one image runs the same CLI. An image without a baked CLI
/// downloads that same pinned release for its architecture and installs it only once
/// its SHA-256 matches the pin, so no unverified script ever runs (#74). Either way
/// the step is guarded by `command -v`, so a CLI already on PATH or an
/// init-container retry is a no-op.
final class ClaudeSetup : AgentSetup, CliReport
{
	private string bakedCli;
	private const(ClaudePackage)[] packages;

	/// `bakedCli` is where the image bakes its pinned CLI; `packages` are the
	/// per-architecture releases the fallback may download.
	this(string bakedCli = claudeStageSource, in ClaudePackage[] packages = claudePackages) @safe
	{
		this.bakedCli = bakedCli;
		this.packages = packages;
	}

	override string name() const @safe
	{
		return "claude";
	}

	override string[] requires() const @safe
	{
		if (baked)
			return ["sh"];
		return ["bash", "curl", "sha256sum"];
	}

	override string[][] installSteps() const @safe
	{
		if (baked)
			return [[
				"sh", "-c",
				`command -v claude >/dev/null 2>&1 || { mkdir -p "$HOME/.local/bin" && cp '`
					~ bakedCli ~ `' "$HOME/.local/bin/claude" && chmod +x "$HOME/.local/bin/claude"; }`,
			]];
		const architectures = packages
			.map!(p => "\n  " ~ p.machine ~ ") platform=" ~ p.platform ~ " sha256=" ~ p.sha256 ~ " ;;")
			.join;
		return [[
			"bash", "-euo", "pipefail", "-c",
			`command -v claude >/dev/null 2>&1 && exit 0
case "$(uname -m)" in` ~ architectures ~ `
  *) echo "no Claude CLI release for $(uname -m)" >&2; exit 1 ;;
esac
mkdir -p "$HOME/.local/bin"
download="$HOME/.local/bin/claude.download"
curl -fsSL -o "$download" "https://downloads.claude.ai/claude-code-releases/` ~ claudeCliVersion ~ `/$platform/claude"
echo "$sha256  $download" | sha256sum -c - >/dev/null || { rm -f "$download"; exit 1; }
chmod 0755 "$download"
mv "$download" "$HOME/.local/bin/claude"`,
		]];
	}

	override CliOrigin origin() const
	{
		if (findExecutable("claude").length)
			return CliOrigin.present;
		return baked ? CliOrigin.baked : CliOrigin.downloaded;
	}

	override string[] versionCommand() const @safe
	{
		return ["claude", "--version"];
	}

	private bool baked() const @safe
	{
		return bakedCli.exists;
	}
}

version (unittest)
{
	import fluent.asserts;
	import std.algorithm.searching : canFind;
	import std.conv : octal;
	import std.file : mkdirRecurse, readText, rmdirRecurse, setAttributes, symlink, tempDir, write;
	import std.path : buildPath;
	import std.process : Config, execute;
	import std.string : strip;

	/// A throwaway pod in a temp dir: an empty HOME, a `bin` that is the whole PATH
	/// (only the tools a step may use, plus a stand-in `curl` that logs its calls),
	/// and an `image` dir where a test can bake a CLI.
	struct Sandbox
	{
		string root;
		string home;
		string bin;
		string baked;
		string curlLog;
	}

	Sandbox sandbox(string name)
	{
		Sandbox box;
		box.root = buildPath(tempDir, "agentcore-claude-setup-" ~ name);
		if (box.root.exists)
			rmdirRecurse(box.root);
		box.home = buildPath(box.root, "home");
		box.bin = buildPath(box.root, "bin");
		box.baked = buildPath(box.root, "image", "claude");
		box.curlLog = buildPath(box.root, "curl.log");
		mkdirRecurse(box.home);
		mkdirRecurse(box.bin);
		mkdirRecurse(buildPath(box.root, "image"));

		foreach (tool; ["bash", "sh", "mkdir", "cp", "chmod", "cat", "printf", "mv", "rm", "uname", "sha256sum"])
			symlink(findExecutable(tool), buildPath(box.bin, tool));

		// The release server, as far as the step can tell: it records the call and
		// writes the `-o` file with a CLI reporting 9.9.9.
		writeExecutable(buildPath(box.bin, "curl"), "#!/bin/sh\necho \"$@\" >> '" ~ box.curlLog ~ "'\n"
			~ `while [ "$1" != "-o" ]; do shift; done; cp '` ~ fakeRelease(box) ~ `' "$2"` ~ "\n");
		return box;
	}

	/// The CLI the stand-in release server hands out.
	string fakeRelease(in Sandbox box)
	{
		const path = buildPath(box.root, "release-claude");
		if (!path.exists)
			writeExecutable(path, "#!/bin/sh\necho '9.9.9 (Claude Code)'\n");
		return path;
	}

	/// The release pin for this host's architecture, with `sha256` in place of the real one.
	ClaudePackage[] pinnedTo(string sha256)
	{
		import std.algorithm.iteration : map;
		import std.array : array;

		return claudePackages.map!(p => ClaudePackage(p.machine, p.platform, sha256)).array;
	}

	string sha256Hex(string path)
	{
		import std.digest : LetterCase, toHexString;
		import std.digest.sha : sha256Of;
		import std.file : read;

		return sha256Of(read(path)).toHexString!(LetterCase.lower).idup;
	}

	void writeExecutable(string path, string script)
	{
		write(path, script);
		setAttributes(path, octal!755);
	}

	/// The pod's PATH layout: the CLI's install dir in HOME first, then the tools.
	string podPath(in Sandbox box)
	{
		return buildPath(box.home, ".local", "bin") ~ ":" ~ box.bin;
	}

	/// Run one install step inside `box`, with the pod's PATH and nothing from the
	/// host's environment.
	auto runIn(in Sandbox box, string[] step)
	{
		return execute(step, ["HOME": box.home, "PATH": podPath(box)], Config.newEnv);
	}

	/// `setup.origin` as the init would see it inside `box` — its PATH, not the host's.
	CliOrigin originIn(in Sandbox box, in ClaudeSetup setup)
	{
		import std.process : environment;

		const hostPath = environment.get("PATH", "");
		environment["PATH"] = podPath(box);
		scope (exit)
			environment["PATH"] = hostPath;
		return setup.origin;
	}

	string installedVersion(in Sandbox box)
	{
		return execute([buildPath(box.home, ".local", "bin", "claude"), "--version"]).output.strip;
	}
}

@safe unittest
{
	auto claude = new ClaudeSetup("/nonexistent/baked/claude");
	claude.name.should.equal("claude");
	claude.requires.should.equal(["bash", "curl", "sha256sum"]);

	auto steps = claude.installSteps;
	steps.length.should.equal(1);
	steps[0][0 .. 4].should.equal(["bash", "-euo", "pipefail", "-c"]);
	// #74: never an unpinned installer piped into a shell.
	steps[0][4].canFind("install.sh").should.equal(false);
	steps[0][4].canFind("command -v claude").should.equal(true);
}

unittest
{
	// A CLI baked into the image is copied into HOME: no download, and the copy
	// reports the image's version.
	auto box = sandbox("baked");
	scope (exit)
		rmdirRecurse(box.root);
	writeExecutable(box.baked, "#!/bin/sh\necho '2.1.311 (Claude Code)'\n");

	auto claude = new ClaudeSetup(box.baked);
	originIn(box, claude).should.equal(CliOrigin.baked);
	claude.requires.should.equal(["sh"]);

	foreach (step; claude.installSteps)
		runIn(box, step).status.should.equal(0);

	box.curlLog.exists.should.equal(false);
	installedVersion(box).should.equal("2.1.311 (Claude Code)");
}

unittest
{
	// An init-container retry finds the copy already in HOME and leaves it be.
	auto box = sandbox("baked-retry");
	scope (exit)
		rmdirRecurse(box.root);
	writeExecutable(box.baked, "#!/bin/sh\necho '2.1.311 (Claude Code)'\n");
	auto claude = new ClaudeSetup(box.baked);

	foreach (attempt; 0 .. 2)
		foreach (step; claude.installSteps)
			runIn(box, step).status.should.equal(0);

	installedVersion(box).should.equal("2.1.311 (Claude Code)");
}

unittest
{
	// #74: an image without a baked CLI downloads the pinned release for its architecture
	// and installs it once its checksum matches the pin.
	auto box = sandbox("download");
	scope (exit)
		rmdirRecurse(box.root);

	auto claude = new ClaudeSetup(box.baked, pinnedTo(sha256Hex(fakeRelease(box))));
	originIn(box, claude).should.equal(CliOrigin.downloaded);

	foreach (step; claude.installSteps)
		runIn(box, step).status.should.equal(0);

	const platform = execute(["uname", "-m"]).output.strip == "aarch64" ? "linux-arm64" : "linux-x64";
	readText(box.curlLog).canFind("https://downloads.claude.ai/claude-code-releases/" ~ claudeCliVersion
		~ "/" ~ platform ~ "/claude").should.equal(true);
	installedVersion(box).should.equal("9.9.9 (Claude Code)");
}

unittest
{
	// #74: a download whose checksum is not the pin fails the step and installs nothing.
	auto box = sandbox("tampered");
	scope (exit)
		rmdirRecurse(box.root);

	auto claude = new ClaudeSetup(box.baked, pinnedTo("0000000000000000000000000000000000000000000000000000000000000000"));
	foreach (step; claude.installSteps)
		runIn(box, step).status.should.not.equal(0);

	buildPath(box.home, ".local", "bin", "claude").exists.should.equal(false);
}

unittest
{
	import std.path : buildNormalizedPath, dirName;

	// #74: the fallback pins the same CLI the agent image bakes.
	const dockerfile = readText(buildNormalizedPath(dirName(__FILE_FULL_PATH__),
		"../../../../../../scripts/container/Dockerfile.agent"));
	dockerfile.canFind("ARG CLAUDE_CLI_VERSION=" ~ claudeCliVersion ~ "\n").should.equal(true);
	dockerfile.canFind("ARG CLAUDE_CLI_SHA256_AMD64=" ~ claudePackages[0].sha256 ~ "\n").should.equal(true);
	dockerfile.canFind("ARG CLAUDE_CLI_SHA256_ARM64=" ~ claudePackages[1].sha256 ~ "\n").should.equal(true);
}

unittest
{
	// A CLI already on PATH (an image that ships its own) is neither copied nor
	// downloaded, and says so.
	auto box = sandbox("present");
	scope (exit)
		rmdirRecurse(box.root);
	writeExecutable(box.baked, "#!/bin/sh\necho '2.1.311 (Claude Code)'\n");
	writeExecutable(buildPath(box.bin, "claude"), "#!/bin/sh\necho '1.0.0 (Claude Code)'\n");

	auto claude = new ClaudeSetup(box.baked);
	originIn(box, claude).should.equal(CliOrigin.present);

	foreach (step; claude.installSteps)
		runIn(box, step).status.should.equal(0);

	buildPath(box.home, ".local", "bin", "claude").exists.should.equal(false);
	box.curlLog.exists.should.equal(false);
}

unittest
{
	// The version is read from the installed CLI's own `--version` line.
	auto claude = new ClaudeSetup("/nonexistent/baked/claude");
	claude.versionCommand.should.equal(["claude", "--version"]);
}
