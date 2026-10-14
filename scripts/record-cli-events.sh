#!/usr/bin/env bash
# Record an agent CLI's stream-json events for a single-turn, no-tool run into
# <testdata>/events/<vendor>-cli.jsonl (default testdata: packages/agentcore/testdata).
#
# Usage: record-cli-events.sh [testdata] [claude|gemini]   (vendor defaults to claude)
#
# claude: uses the CLI version pinned in scripts/container/Dockerfile.agent (downloaded and
# checksum-verified, as the image build does) with the flags vendors/claude/agent.d passes.
# Needs ANTHROPIC_API_KEY; the run costs one claude-haiku-5-5 call. Set CLAUDE_CLI to an
# installed binary to skip the download.
#
# gemini: uses the @google/gemini-cli version pinned in vendors/gemini/setup.d
# (geminiCliVersion, fetched from the npm registry as the init container does; needs node)
# with the flags vendors/gemini/agent.d passes. Needs GEMINI_API_KEY; the run costs one
# gemini-3.1-flash-lite call. Set GEMINI_CLI to an installed binary (e.g. /usr/local/bin/gemini)
# to skip the download.
#
# Either way the fixture is what a run pod prints; with a CLI override the recording
# reflects that version, not the pinned one. Each run gets an isolated HOME.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
testdata="$(realpath -m "${1:-$repo/packages/agentcore/testdata}")"
vendor="${2:-claude}"
dockerfile="$repo/scripts/container/Dockerfile.agent"
prompt="Reply with the single word: ok"

pinned() {
	sed -n "s/^ARG $1=//p" "$dockerfile"
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

download_pinned_claude() {
	local platform sha version
	case "$(uname -m)" in
	x86_64) platform=linux-x64 sha="$(pinned CLAUDE_CLI_SHA256_AMD64)" ;;
	aarch64 | arm64) platform=linux-arm64 sha="$(pinned CLAUDE_CLI_SHA256_ARM64)" ;;
	*)
		echo "unsupported machine: $(uname -m)" >&2
		exit 1
		;;
	esac
	version="$(pinned CLAUDE_CLI_VERSION)"
	curl -fsSL -o "$scratch/claude" "https://downloads.claude.ai/claude-code-releases/$version/$platform/claude"
	echo "$sha  $scratch/claude" | sha256sum -c - >/dev/null
	chmod 0755 "$scratch/claude"
	echo "$scratch/claude"
}

download_pinned_gemini() {
	local version
	version="$(sed -n 's/^enum geminiCliVersion = "\(.*\)";/\1/p' "$repo/packages/agentcore/source/agentcore/vendors/gemini/setup.d")"
	mkdir -p "$scratch/gemini-cli"
	curl -fsSL "https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-$version.tgz" | tar -xz -C "$scratch/gemini-cli"
	printf '#!/usr/bin/env bash\nexec node "%s/gemini-cli/package/bundle/gemini.js" "$@"\n' "$scratch" >"$scratch/gemini"
	chmod 0755 "$scratch/gemini"
	echo "$scratch/gemini"
}

case "$vendor" in
claude)
	: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"
	cli="${CLAUDE_CLI:-$(download_pinned_claude)}"
	run() { "$cli" --print --verbose --output-format stream-json --model claude-haiku-5-5 -- "$prompt"; }
	succeeded='"is_error":false'
	;;
gemini)
	: "${GEMINI_API_KEY:?GEMINI_API_KEY must be set}"
	cli="${GEMINI_CLI:-$(download_pinned_gemini)}"
	run() {
		"$cli" --prompt "$prompt" --output-format stream-json --model gemini-3.1-flash-lite --skip-trust
	}
	succeeded='"status":"success"'
	;;
*)
	echo "unknown vendor: $vendor (want claude or gemini)" >&2
	exit 1
	;;
esac

recording="$scratch/$vendor-cli.jsonl"
mkdir -p "$scratch/home" "$scratch/work" "$testdata/events"
(
	cd "$scratch/work"
	HOME="$scratch/home" run
) >"$recording" || true

if ! tail -n 1 "$recording" | grep -q "$succeeded"; then
	echo "$vendor CLI run failed; its last event:" >&2
	tail -n 1 "$recording" >&2 || true
	exit 1
fi
mv "$recording" "$testdata/events/$vendor-cli.jsonl"

echo "recorded $vendor $("$cli" --version) events to $testdata/events/$vendor-cli.jsonl" >&2
