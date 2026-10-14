#!/usr/bin/env bash
# Live event-parity check: record a real CLI run and a real batch round trip for one
# vendor, put the recordings in place of packages/agentcore/testdata's fixtures, and run
# `dub test :agentcore`, whose contract and structural-diff tests compare the two. The
# original fixtures are restored afterwards unless KEEP_FIXTURES=1.
# VENDOR=claude (default) needs ANTHROPIC_API_KEY; VENDOR=gemini needs GEMINI_API_KEY;
# VENDOR=openai (the codex CLI against the OpenAI Batch API) needs OPENAI_API_KEY.
# SKIP_CLI=1 records only the batch round trip and keeps the CLI fixture as it is.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
testdata="$repo/packages/agentcore/testdata"
vendor="${VENDOR:-claude}"

case "$vendor" in
claude)
	: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"
	batch_vendor=anthropic
	fixtures=(batch/anthropic-batch-ended.json batch/anthropic-result-succeeded.json)
	;;
gemini)
	: "${GEMINI_API_KEY:?GEMINI_API_KEY must be set}"
	batch_vendor=gemini
	fixtures=(batch/gemini-batch-succeeded.json)
	;;
openai)
	: "${OPENAI_API_KEY:?OPENAI_API_KEY must be set}"
	batch_vendor=openai
	vendor=codex
	fixtures=(batch/openai-batch-completed.json batch/openai-output-succeeded.json)
	;;
*)
	echo "unknown VENDOR: $vendor (want claude, gemini or openai)" >&2
	exit 1
	;;
esac
if [ "${SKIP_CLI:-0}" != 1 ]; then
	fixtures+=("events/$vendor-cli.jsonl")
fi

recorded="$(mktemp -d)"
backup="$(mktemp -d)"

restore() {
	if [ "${KEEP_FIXTURES:-0}" != 1 ]; then
		for fixture in "${fixtures[@]}"; do
			cp "$backup/$fixture" "$testdata/$fixture"
		done
	fi
	rm -rf "$recorded" "$backup"
}

if [ "${SKIP_CLI:-0}" != 1 ]; then
	"$repo/scripts/record-cli-events.sh" "$recorded" "$vendor"
fi
"$repo/scripts/record-batch-response.sh" "$recorded" "$batch_vendor"

trap restore EXIT
for fixture in "${fixtures[@]}"; do
	mkdir -p "$(dirname "$backup/$fixture")"
	cp "$testdata/$fixture" "$backup/$fixture"
	cp "$recorded/$fixture" "$testdata/$fixture"
done

cd "$repo"
dub test :agentcore
