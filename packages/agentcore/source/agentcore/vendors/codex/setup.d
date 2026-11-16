module agentcore.vendors.codex.setup;

import std.algorithm.iteration : map;
import std.array : join;

import agentcore.core.env : envProvider, foundryProvider, unsupportedProviderMessage;
import agentcore.vendors.base.setup : AgentSetup, ProviderSettings;
import agentcore.vendors.codex.agent : foundryApiKeyKey, foundryBaseUrlKey;


/// The Codex CLI release every run installs. Pinned, because a release can change
/// what a run needs: 0.142 stopped reading OPENAI_API_KEY in `codex exec`, and the
/// unpinned installer shipped that to run pods unannounced. Raise it deliberately,
/// together with the checksums in `codexPackages`.
enum codexCliVersion = "0.167.1";

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
		"a945df3df83e849dd7b74787e27f8a459c1946b0e3afe3dc8eef8a8d1845fd4f"),
	CodexPackage("aarch64", "aarch64-unknown-linux-musl",
		"ef3e1443a7795d596f1601a533d7225a1030488d60c965af1f0610ab95889031"),
];

/// Install the pinned OpenAI Codex CLI from its GitHub release package — the
/// archive the official `install.sh` installs, minus its "latest" lookup. The step
/// picks the package for the pod's architecture, verifies its SHA-256 against the
/// pin before extracting anything, unpacks it where `install.sh` would
/// (`~/.codex/packages/standalone/releases/<version>-<target>`, next to the bundled
/// `rg` and `bwrap` the CLI looks for) and links `codex` into `~/.local/bin`. No
/// Node runtime is needed. Guarded by `command -v` so a pre-baked CLI (the
/// integration-test mock) or an init-container retry is a no-op.
final class CodexSetup : AgentSetup, ProviderSettings
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

	/// Write the Foundry model provider into `~/.codex/config.toml`, pointing Codex at
	/// the endpoint in `AZURE_OPENAI_BASE_URL`. The API key is never written: `env_key`
	/// only names the variable Codex reads it from, so the secret stays in the pod's
	/// environment and out of the file. The selection line goes before any existing
	/// content because TOML keys after a `[table]` header belong to that table, and a
	/// hook bundle's config.toml usually has one. The new file is built beside the old
	/// and renamed over it, so a failure leaves the old config whole. A config that
	/// already holds the foundry table is left alone, which makes a retry a no-op.
	override string[][] providerSteps() const @safe
	{
		return [[
			"bash", "-euo", "pipefail", "-c",
			`[ -n "${` ~ envProvider ~ `:-}" ] || exit 0
[ "$` ~ envProvider ~ `" = "` ~ foundryProvider ~ `" ] || {
  echo "` ~ unsupportedProviderMessage("$" ~ envProvider) ~ `" >&2
  exit 1
}
[ -n "${` ~ foundryBaseUrlKey ~ `:-}" ] || {
  echo "` ~ envProvider ~ `=` ~ foundryProvider ~ ` needs ` ~ foundryBaseUrlKey ~ ` in agent-secrets" >&2
  exit 1
}
mkdir -p "$HOME/.codex"
config="$HOME/.codex/config.toml"
if [ -f "$config" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != '[model_providers.` ~ foundryProvider ~ `]' ] || exit 0
  done < "$config"
fi
{
  printf '%s\n' 'model_provider = "` ~ foundryProvider ~ `"'
  [ ! -f "$config" ] || cat "$config"
  printf '%s\n' \
    '' \
    '[model_providers.` ~ foundryProvider ~ `]' \
    'name = "Azure OpenAI"' \
    "base_url = \"$` ~ foundryBaseUrlKey ~ `\"" \
    'env_key = "` ~ foundryApiKeyKey ~ `"' \
    'wire_api = "responses"'
} > "$config.new"
mv "$config.new" "$config"`,
		]];
	}
}

version (unittest)
{
	import fluent.asserts;
	import std.algorithm.iteration : filter;
	import std.algorithm.searching : all, canFind;
	import std.array : array;
	import std.conv : octal;
	import std.digest : LetterCase, toHexString;
	import std.digest.sha : sha256Of;
	import std.file : exists, mkdirRecurse, read, readText, rmdirRecurse, setAttributes, symlink, tempDir, write;
	import std.path : buildPath;
	import std.process : Config, execute;
	import std.string : splitLines, strip;

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

		foreach (tool; ["bash", "sh", "mkdir", "tar", "gzip", "sha256sum", "ln", "rm", "cp", "cat", "mv"])
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
	auto runIn(in Sandbox box, string[] step, const string[string] podEnv = null)
	{
		const path = buildPath(box.home, ".local", "bin") ~ ":" ~ box.bin;
		string[string] env = ["HOME": box.home, "PATH": path];
		foreach (name, value; podEnv)
			env[name] = value;
		return execute(step, env, Config.newEnv);
	}

	/// The one provider step run in `box` with `podEnv`: its message, whether it failed,
	/// and whether it left a config behind.
	string[] providerFailure(in Sandbox box, const string[string] podEnv)
	{
		const result = runIn(box, (new CodexSetup).providerSteps[0], podEnv);
		return [
			result.output.strip,
			result.status != 0 ? "fails" : "succeeds",
			buildPath(box.home, ".codex", "config.toml").exists ? "writes config" : "writes no config",
		];
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

@safe unittest // pinned install step downloads the 0.167.1 musl packages, never the latest installer
{
	const steps = (new CodexSetup).installSteps;
	steps.length.should.equal(1);
	steps[0][0 .. 4].should.equal(["bash", "-euo", "pipefail", "-c"]);
	steps[0][4].canFind("https://chatgpt.com/codex/install.sh").should.equal(false);
	steps[0][4].canFind("https://github.com/openai/codex/releases/download/rust-v0.167.1/codex-package-")
		.should.equal(true);
	steps[0][4].canFind("a945df3df83e849dd7b74787e27f8a459c1946b0e3afe3dc8eef8a8d1845fd4f").should.equal(true);
	steps[0][4].canFind("ef3e1443a7795d596f1601a533d7225a1030488d60c965af1f0610ab95889031").should.equal(true);
}

unittest // x86_64 pod installs the x86_64 musl package as ~/.local/bin/codex
{
	auto box = sandbox("x86_64", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);

	foreach (step; (new CodexSetup(fakePackages(box))).installSteps)
		runIn(box, step).status.should.equal(0);

	readText(box.curlLog).canFind("rust-v0.167.1/codex-package-x86_64-unknown-linux-musl.tar.gz").should.equal(true);
	installedVersion(box).should.equal("codex-cli 9.9.9");
}

unittest // aarch64 pod installs the aarch64 musl package
{
	auto box = sandbox("aarch64", "aarch64");
	scope (exit)
		rmdirRecurse(box.root);

	foreach (step; (new CodexSetup(fakePackages(box))).installSteps)
		runIn(box, step).status.should.equal(0);

	readText(box.curlLog).canFind("rust-v0.167.1/codex-package-aarch64-unknown-linux-musl.tar.gz").should.equal(true);
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

unittest // foundry provider steps write the foundry model provider block into ~/.codex/config.toml
{
	auto box = sandbox("foundry", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);
	const podEnv = [
		"AGENT_PROVIDER": "foundry",
		"AZURE_OPENAI_BASE_URL": "https://my-foundry.openai.azure.com/openai/v1",
	];

	foreach (step; (new CodexSetup).providerSteps)
		runIn(box, step, podEnv.dup).status.should.equal(0);

	readText(buildPath(box.home, ".codex", "config.toml")).strip.should.equal(
		"model_provider = \"foundry\"\n\n"
		~ "[model_providers.foundry]\n"
		~ "name = \"Azure OpenAI\"\n"
		~ "base_url = \"https://my-foundry.openai.azure.com/openai/v1\"\n"
		~ "env_key = \"AZURE_OPENAI_API_KEY\"\n"
		~ "wire_api = \"responses\"");
}

unittest // provider steps succeed and write no ~/.codex/config.toml when the pod has no AGENT_PROVIDER or AZURE_OPENAI_BASE_URL
{
	auto box = sandbox("unswitched", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);

	int[] statuses;
	foreach (step; (new CodexSetup).providerSteps)
		statuses ~= runIn(box, step).status;

	[statuses.all!(status => status == 0), buildPath(box.home, ".codex", "config.toml").exists]
		.should.equal([true, false]);
}

unittest // unsupported AGENT_PROVIDER bedrock fails the step with the supported list and writes no ~/.codex/config.toml
{
	auto box = sandbox("unsupported", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);
	const podEnv = [
		"AGENT_PROVIDER": "bedrock",
		"AZURE_OPENAI_BASE_URL": "https://my-foundry.openai.azure.com/openai/v1",
	];

	providerFailure(box, podEnv).should.equal([
		"unsupported AGENT_PROVIDER 'bedrock' (supported: foundry)",
		"fails",
		"writes no config",
	]);
}

unittest // AGENT_PROVIDER foundry without AZURE_OPENAI_BASE_URL fails the step naming the missing variable and writes no ~/.codex/config.toml
{
	auto box = sandbox("missing-base-url", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);
	const podEnv = ["AGENT_PROVIDER": "foundry"];

	providerFailure(box, podEnv).should.equal([
		"AGENT_PROVIDER=foundry needs AZURE_OPENAI_BASE_URL in agent-secrets",
		"fails",
		"writes no config",
	]);
}

unittest // existing ~/.codex/config.toml keeps its lines between the model_provider line and the foundry table, empty lines ignored
{
	auto box = sandbox("existing-config", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);
	mkdirRecurse(buildPath(box.home, ".codex"));
	write(buildPath(box.home, ".codex", "config.toml"),
		"approval_policy = \"never\"\n\n[features]\nweb_search = true\n");
	const podEnv = [
		"AGENT_PROVIDER": "foundry",
		"AZURE_OPENAI_BASE_URL": "https://my-foundry.openai.azure.com/openai/v1",
	];

	foreach (step; (new CodexSetup).providerSteps)
		runIn(box, step, podEnv.dup).status.should.equal(0);

	readText(buildPath(box.home, ".codex", "config.toml")).splitLines.filter!(line => line.strip.length).array
		.should.equal([
			"model_provider = \"foundry\"",
			"approval_policy = \"never\"",
			"[features]",
			"web_search = true",
			"[model_providers.foundry]",
			"name = \"Azure OpenAI\"",
			"base_url = \"https://my-foundry.openai.azure.com/openai/v1\"",
			"env_key = \"AZURE_OPENAI_API_KEY\"",
			"wire_api = \"responses\"",
		]);
}

unittest // second foundry provider run succeeds and leaves ~/.codex/config.toml byte-for-byte as the first run left it
{
	auto box = sandbox("provider-retry", "x86_64");
	scope (exit)
		rmdirRecurse(box.root);
	const podEnv = [
		"AGENT_PROVIDER": "foundry",
		"AZURE_OPENAI_BASE_URL": "https://my-foundry.openai.azure.com/openai/v1",
	];
	const configPath = buildPath(box.home, ".codex", "config.toml");
	auto step = (new CodexSetup).providerSteps[0];

	runIn(box, step, podEnv.dup).status.should.equal(0);
	const firstRun = readText(configPath);
	const secondStatus = runIn(box, step, podEnv.dup).status;

	secondStatus.should.equal(0);
	readText(configPath).should.equal(firstRun);
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
