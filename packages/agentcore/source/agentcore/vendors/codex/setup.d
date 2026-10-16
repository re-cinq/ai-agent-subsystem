module agentcore.vendors.codex.setup;

import std.algorithm.iteration : map;
import std.array : join;

import agentcore.vendors.base.setup : AgentSetup;

/// The Codex CLI release every run installs. Pinned, because a release can change
/// what a run needs: 0.142 stopped reading OPENAI_API_KEY in `codex exec`, and the
/// unpinned installer shipped that to run pods unannounced. Raise it deliberately,
/// together with the checksums in `codexPackages`.
enum codexCliVersion = "0.142.5";

/// One architecture's Codex release package: the `uname -m` it serves, the release
/// target it names, and the SHA-256 of its `codex-package-<target>.tar.gz` (the
/// release's `codex-package_SHA256SUMS`).
struct CodexPackage
{
	string machine;
	string target;
	string sha256;
}

/// The statically linked musl packages of `codexCliVersion`: they run on any Linux
/// base image, glibc or musl.
immutable CodexPackage[] codexPackages = [
	CodexPackage("x86_64", "x86_64-unknown-linux-musl",
		"14ab953574506cb30d8c773e5a3458fd0a2d1aad58062f0a98ea6a159889b80e"),
	CodexPackage("aarch64", "aarch64-unknown-linux-musl",
		"600d444443e8ec04397586965fde7de77de7795842f5e7b0e622c7b05f7fc356"),
];

/// Install the pinned OpenAI Codex CLI from its GitHub release package — the
/// archive the official `install.sh` installs, minus its "latest" lookup. The step
/// picks the package for the pod's architecture, verifies its SHA-256 against the
/// pin before extracting anything, unpacks it where `install.sh` would
/// (`~/.codex/packages/standalone/releases/<version>-<target>`, next to the bundled
/// `rg` and `bwrap` the CLI looks for) and links `codex` into `~/.local/bin`. No
/// Node runtime is needed. Guarded by `command -v` so a pre-baked CLI (the
/// integration-test mock) or an init-container retry is a no-op.
final class CodexSetup : AgentSetup
{
	private const(CodexPackage)[] packages;

	/// `packages` are the per-architecture archives the step may install.
	this(in CodexPackage[] packages = codexPackages) @safe
	{
		this.packages = packages;
	}

	override string name() const @safe
	{
		return "codex";
	}

	override string[] requires() const @safe
	{
		return ["bash", "curl", "tar", "sha256sum"];
	}

	override string[][] installSteps() const @safe
	{
		const architectures = packages
			.map!(p => "\n  " ~ p.machine ~ ") target=" ~ p.target ~ " sha256=" ~ p.sha256 ~ " ;;")
			.join;
		return [[
			"bash", "-euo", "pipefail", "-c",
			`command -v codex >/dev/null 2>&1 && exit 0
case "$(uname -m)" in` ~ architectures ~ `
  *) echo "no Codex CLI package for $(uname -m)" >&2; exit 1 ;;
esac
release="$HOME/.codex/packages/standalone/releases/` ~ codexCliVersion ~ `-$target"
archive="$release.tar.gz"
mkdir -p "$release" "$HOME/.local/bin"
curl -fsSL -o "$archive" "https://github.com/openai/codex/releases/download/rust-v` ~ codexCliVersion ~ `/codex-package-$target.tar.gz"
echo "$sha256  $archive" | sha256sum -c - >/dev/null
tar -xzf "$archive" -C "$release"
rm -f "$archive"
ln -sf "$release/bin/codex" "$HOME/.local/bin/codex"`,
		]];
	}
}

version (unittest)
{
	import fluent.asserts;
	import std.algorithm.searching : canFind;
	import std.conv : octal;
	import std.digest : LetterCase, toHexString;
	import std.digest.sha : sha256Of;
	import std.file : exists, mkdirRecurse, read, readText, rmdirRecurse, setAttributes, symlink, tempDir, write;
	import std.path : buildPath;
	import std.process : Config, execute;
	import std.string : strip;

	import agentcore.core.exec : findExecutable;

	/// A throwaway pod in a temp dir: an empty HOME and a `bin` that is the whole
	/// PATH — the tools the step may use, a `uname` reporting `machine`, and a
	/// stand-in `curl` that logs its calls and serves a fake Codex package whose CLI
	/// reports 9.9.9.
	struct Sandbox
	{
		string root;
		string home;
		string bin;
		string curlLog;
		string packageSha256;
	}

	Sandbox sandbox(string name, string machine)
	{
		Sandbox box;
		box.root = buildPath(tempDir, "agentcore-codex-setup-" ~ name);
		if (box.root.exists)
			rmdirRecurse(box.root);
		box.home = buildPath(box.root, "home");
		box.bin = buildPath(box.root, "bin");
		box.curlLog = buildPath(box.root, "curl.log");
		mkdirRecurse(box.home);
		mkdirRecurse(box.bin);

		foreach (tool; ["bash", "sh", "mkdir", "tar", "gzip", "sha256sum", "ln", "rm", "cp"])
			symlink(findExecutable(tool), buildPath(box.bin, tool));
		writeExecutable(buildPath(box.bin, "uname"), "#!/bin/sh\necho " ~ machine ~ "\n");

		const package_ = buildPath(box.root, "package");
		mkdirRecurse(buildPath(package_, "bin"));
		writeExecutable(buildPath(package_, "bin", "codex"), "#!/bin/sh\necho 'codex-cli 9.9.9'\n");
		const archive = buildPath(box.root, "codex-package.tar.gz");
		execute(["tar", "-czf", archive, "-C", package_, "bin"]).status.should.equal(0);
		box.packageSha256 = sha256Of(cast(const(ubyte)[]) read(archive)).toHexString!(LetterCase.lower).idup;

		writeExecutable(buildPath(box.bin, "curl"), "#!/bin/sh\necho \"$@\" >> '" ~ box.curlLog ~ "'\n"
			~ "while [ $# -gt 0 ]; do\n\t[ \"$1\" = -o ] && cp '" ~ archive ~ "' \"$2\"\n\tshift\ndone\n");
		return box;
	}

	void writeExecutable(string path, string script)
	{
		write(path, script);
		setAttributes(path, octal!755);
	}

	/// The pinned packages, with the fake package's checksum in place of the real ones.
	CodexPackage[] fakePackages(in Sandbox box)
	{
		CodexPackage[] packages;
		foreach (pinned; codexPackages)
			packages ~= CodexPackage(pinned.machine, pinned.target, box.packageSha256);
		return packages;
	}

	/// Run one install step inside `box`, with the pod's PATH (the CLI's install dir
	/// in HOME first) and nothing from the host's environment.
	auto runIn(in Sandbox box, string[] step)
	{
		const path = buildPath(box.home, ".local", "bin") ~ ":" ~ box.bin;
		return execute(step, ["HOME": box.home, "PATH": path], Config.newEnv);
	}

	string installedVersion(in Sandbox box)
	{
		return execute([buildPath(box.home, ".local", "bin", "codex"), "--version"]).output.strip;
	}
}

@safe unittest // codex setup requires bash, curl, tar and sha256sum
{
	auto codex = new CodexSetup;
	codex.name.should.equal("codex");
	codex.requires.should.equal(["bash", "curl", "tar", "sha256sum"]);
}

@safe unittest // pinned install step downloads the 0.142.5 musl packages, never the latest installer
{
	const steps = (new CodexSetup).installSteps;
	steps.length.should.equal(1);
	steps[0][0 .. 4].should.equal(["bash", "-euo", "pipefail", "-c"]);
	steps[0][4].canFind("https://chatgpt.com/codex/install.sh").should.equal(false);
	steps[0][4].canFind("https://github.com/openai/codex/releases/download/rust-v0.142.5/codex-package-")
		.should.equal(true);
	steps[0][4].canFind("14ab953574506cb30d8c773e5a3458fd0a2d1aad58062f0a98ea6a159889b80e").should.equal(true);
	steps[0][4].canFind("600d444443e8ec04397586965fde7de77de7795842f5e7b0e622c7b05f7fc356").should.equal(true);
}

unittest // x86_64 pod installs the x86_64 musl package as ~/.local/bin/codex
{
	auto box = sandbox("x86_64", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);

	foreach (step; (new CodexSetup(fakePackages(box))).installSteps)
		runIn(box, step).status.should.equal(0);

	readText(box.curlLog).canFind("rust-v0.142.5/codex-package-x86_64-unknown-linux-musl.tar.gz").should.equal(true);
	installedVersion(box).should.equal("codex-cli 9.9.9");
}

unittest // aarch64 pod installs the aarch64 musl package
{
	auto box = sandbox("aarch64", "aarch64");
	scope (exit)
		rmdirRecurse(box.root);

	foreach (step; (new CodexSetup(fakePackages(box))).installSteps)
		runIn(box, step).status.should.equal(0);

	readText(box.curlLog).canFind("rust-v0.142.5/codex-package-aarch64-unknown-linux-musl.tar.gz").should.equal(true);
	installedVersion(box).should.equal("codex-cli 9.9.9");
}

unittest // package whose sha256 differs from the pin fails the step and installs nothing
{
	auto box = sandbox("tampered", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);

	foreach (step; (new CodexSetup).installSteps)
		runIn(box, step).status.should.not.equal(0);

	buildPath(box.home, ".local", "bin", "codex").exists.should.equal(false);
}

unittest // riscv64 pod fails the step without downloading
{
	auto box = sandbox("riscv64", "riscv64");
	scope (exit)
		rmdirRecurse(box.root);

	foreach (step; (new CodexSetup(fakePackages(box))).installSteps)
		runIn(box, step).status.should.not.equal(0);

	box.curlLog.exists.should.equal(false);
}

unittest // codex already on PATH is neither downloaded nor replaced
{
	auto box = sandbox("present", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);
	writeExecutable(buildPath(box.bin, "codex"), "#!/bin/sh\necho 'codex-cli 1.0.0'\n");

	foreach (attempt; 0 .. 2)
		foreach (step; (new CodexSetup(fakePackages(box))).installSteps)
			runIn(box, step).status.should.equal(0);

	box.curlLog.exists.should.equal(false);
	buildPath(box.home, ".local", "bin", "codex").exists.should.equal(false);
}

unittest // init-container retry after an install keeps the CLI without downloading again
{
	import std.file : remove;

	auto box = sandbox("retry", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);
	auto codex = new CodexSetup(fakePackages(box));
	foreach (step; codex.installSteps)
		runIn(box, step).status.should.equal(0);
	remove(box.curlLog);

	foreach (step; codex.installSteps)
		runIn(box, step).status.should.equal(0);

	box.curlLog.exists.should.equal(false);
	installedVersion(box).should.equal("codex-cli 9.9.9");
}
