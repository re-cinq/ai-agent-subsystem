module agentcore.vendors.claude.setup;

import std.file : exists;

import agentcore.core.exec : findExecutable;
import agentcore.kube.bundle : claudeStageSource;
import agentcore.vendors.base.setup : AgentSetup, CliOrigin, CliReport;

/// Put the Claude Code CLI on `~/.local/bin` in the shared HOME. The agent image
/// bakes a pinned CLI at `claudeStageSource` (its version is the image's
/// `CLAUDE_CLI_VERSION` build arg), so the init copies that — no network, and
/// every run of one image runs the same CLI. An image without a baked CLI falls
/// back to the official installer, which self-detects OS/arch/libc, verifies a
/// SHA256 checksum from the release manifest, and takes the latest release;
/// `pipefail` plus `curl -f` make a failed download fail the step instead of
/// succeeding silently through the pipe. Either way the step is guarded by
/// `command -v`, so a CLI already on PATH or an init-container retry is a no-op.
final class ClaudeSetup : AgentSetup, CliReport
{
	private string bakedCli;

	/// `bakedCli` is where the image bakes its pinned CLI.
	this(string bakedCli = claudeStageSource) @safe
	{
		this.bakedCli = bakedCli;
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
		return [[
			"bash", "-o", "pipefail", "-c",
			"command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash",
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

		foreach (tool; ["bash", "sh", "mkdir", "cp", "chmod", "cat", "printf"])
			symlink(findExecutable(tool), buildPath(box.bin, tool));

		// The network installer, as far as the step can tell: it records the call
		// and hands back a script that installs a CLI reporting 9.9.9.
		const installer = buildPath(box.root, "install.sh");
		write(installer, `mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
`);
		writeExecutable(buildPath(box.bin, "curl"),
			"#!/bin/sh\necho \"$@\" >> '" ~ box.curlLog ~ "'\ncat '" ~ installer ~ "'\n");
		return box;
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
	steps[0][0 .. 4].should.equal(["bash", "-o", "pipefail", "-c"]);
	steps[0][4].canFind("https://claude.ai/install.sh").should.equal(true);
	steps[0][4].canFind("command -v claude").should.equal(true);
}

unittest
{
	// A CLI baked into the image is copied into HOME: no download, and the copy
	// reports the image's version.
	auto box = sandbox("baked");
	scope (exit)
		rmdirRecurse(box.root);
	writeExecutable(box.baked, "#!/bin/sh\necho '2.1.267 (Claude Code)'\n");

	auto claude = new ClaudeSetup(box.baked);
	originIn(box, claude).should.equal(CliOrigin.baked);
	claude.requires.should.equal(["sh"]);

	foreach (step; claude.installSteps)
		runIn(box, step).status.should.equal(0);

	box.curlLog.exists.should.equal(false);
	installedVersion(box).should.equal("2.1.267 (Claude Code)");
}

unittest
{
	// An init-container retry finds the copy already in HOME and leaves it be.
	auto box = sandbox("baked-retry");
	scope (exit)
		rmdirRecurse(box.root);
	writeExecutable(box.baked, "#!/bin/sh\necho '2.1.267 (Claude Code)'\n");
	auto claude = new ClaudeSetup(box.baked);

	foreach (attempt; 0 .. 2)
		foreach (step; claude.installSteps)
			runIn(box, step).status.should.equal(0);

	installedVersion(box).should.equal("2.1.267 (Claude Code)");
}

unittest
{
	// An image without a baked CLI falls back to the network installer.
	auto box = sandbox("download");
	scope (exit)
		rmdirRecurse(box.root);

	auto claude = new ClaudeSetup(box.baked);
	originIn(box, claude).should.equal(CliOrigin.downloaded);

	foreach (step; claude.installSteps)
		runIn(box, step).status.should.equal(0);

	readText(box.curlLog).canFind("https://claude.ai/install.sh").should.equal(true);
	installedVersion(box).should.equal("9.9.9 (Claude Code)");
}

unittest
{
	// A CLI already on PATH (an image that ships its own) is neither copied nor
	// downloaded, and says so.
	auto box = sandbox("present");
	scope (exit)
		rmdirRecurse(box.root);
	writeExecutable(box.baked, "#!/bin/sh\necho '2.1.267 (Claude Code)'\n");
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
