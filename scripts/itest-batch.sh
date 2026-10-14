#!/usr/bin/env bash
# Live event-parity check: record a real Claude CLI run and a real Anthropic batch
# round trip, put the recordings in place of packages/agentcore/testdata's fixtures,
# and run `dub test :agentcore`, whose contract and structural-diff tests compare the
# two. The original fixtures are restored afterwards unless KEEP_FIXTURES=1.
# Needs ANTHROPIC_API_KEY. SKIP_CLI=1 records only the batch round trip and keeps the
# CLI fixture as it is.
set -euo pipefail

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

repo="$(cd "$(dirname "$0")/.." && pwd)"
testdata="$repo/packages/agentcore/testdata"
fixtures=(batch/anthropic-batch-ended.json batch/anthropic-result-succeeded.json)
if [ "${SKIP_CLI:-0}" != 1 ]; then
	fixtures+=(events/claude-cli.jsonl)
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
	"$repo/scripts/record-cli-events.sh" "$recorded"
fi
"$repo/scripts/record-batch-response.sh" "$recorded"

trap restore EXIT
for fixture in "${fixtures[@]}"; do
	mkdir -p "$(dirname "$backup/$fixture")"
	cp "$testdata/$fixture" "$backup/$fixture"
	cp "$recorded/$fixture" "$testdata/$fixture"
done

cd "$repo"
dub test :agentcore
