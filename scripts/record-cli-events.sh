#!/usr/bin/env bash
# Record the Claude CLI's stream-json events for a single-turn, no-tool run into
# <testdata>/events/claude-cli.jsonl (default testdata: packages/agentcore/testdata).
#
# Uses the CLI version pinned in scripts/container/Dockerfile.agent (downloaded and
# checksum-verified, as the image build does) with the flags vendors/claude/agent.d
# passes, so the fixture is what a run pod prints. Needs ANTHROPIC_API_KEY; the run
# costs one claude-haiku-5-5 call. Set CLAUDE_CLI to an installed binary to skip the
# download (the recording then reflects that version, not the pinned one).
set -euo pipefail

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

repo="$(cd "$(dirname "$0")/.." && pwd)"
testdata="$(realpath -m "${1:-$repo/packages/agentcore/testdata}")"
dockerfile="$repo/scripts/container/Dockerfile.agent"

pinned() {
	sed -n "s/^ARG $1=//p" "$dockerfile"
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

download_pinned_cli() {
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

cli="${CLAUDE_CLI:-$(download_pinned_cli)}"

mkdir -p "$scratch/home" "$scratch/work" "$testdata/events"
(
	cd "$scratch/work"
	HOME="$scratch/home" "$cli" --print --verbose --output-format stream-json \
		--model claude-haiku-5-5 -- "Reply with the single word: ok"
) >"$scratch/claude-cli.jsonl" || true

if ! tail -n 1 "$scratch/claude-cli.jsonl" | grep -q '"is_error":false'; then
	echo "claude CLI run failed; its last event:" >&2
	tail -n 1 "$scratch/claude-cli.jsonl" | grep -o '"result":"[^"]*"\|"terminal_reason":"[^"]*"' >&2 || true
	exit 1
fi
mv "$scratch/claude-cli.jsonl" "$testdata/events/claude-cli.jsonl"

echo "recorded claude $("$cli" --version) events to $testdata/events/claude-cli.jsonl" >&2
