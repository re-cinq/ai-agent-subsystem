#!/usr/bin/env bash
# Record a real Anthropic Message Batches round trip into <testdata>/batch/
# (default testdata: packages/agentcore/testdata): submit a one-request batch with
# the body batch/anthropic.d requestBody builds, poll every 30s until it ends, save
# the ended batch object to anthropic-batch-ended.json and its results line to
# anthropic-result-succeeded.json, then delete the batch. Needs ANTHROPIC_API_KEY;
# the run costs one claude-haiku-5-5 call at the batch price and can take minutes.
set -euo pipefail

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"

repo="$(cd "$(dirname "$0")/.." && pwd)"
testdata="$(realpath -m "${1:-$repo/packages/agentcore/testdata}")"
batches=https://api.anthropic.com/v1/messages/batches

anthropic() {
	curl -fsS -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
		-H "content-type: application/json" "$@"
}

field() {
	tr -d '\n' | sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p"
}

body="$(
	cat <<'JSON'
{"requests":[{"custom_id":"record-fixtures","params":{"model":"claude-haiku-5-5","max_tokens":16000,"messages":[{"role":"user","content":"Reply with the single word: ok"}]}}]}
JSON
)"

id="$(anthropic -X POST --data "$body" "$batches" | field id)"
echo "submitted $id" >&2

while :; do
	batch="$(anthropic "$batches/$id")"
	status="$(field processing_status <<<"$batch")"
	[ "$status" = ended ] && break
	echo "$id is $status; polling again in 30s" >&2
	sleep 30
done

mkdir -p "$testdata/batch"
printf '%s\n' "$batch" >"$testdata/batch/anthropic-batch-ended.json"
anthropic "$(field results_url <<<"$batch")" | head -n 1 >"$testdata/batch/anthropic-result-succeeded.json"
anthropic -X DELETE "$batches/$id" >/dev/null

echo "recorded batch $id to $testdata/batch/" >&2
