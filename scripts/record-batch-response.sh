#!/usr/bin/env bash
# Record a real batch API round trip into <testdata>/batch/ (default testdata:
# packages/agentcore/testdata): submit a one-request batch with the body the vendor's
# batch/<vendor>.d requestBody builds, poll every 30s until it ends, save what it ended
# with, then delete the batch. The run costs one small call at the batch price and can
# take minutes.
#
# Usage: record-batch-response.sh [testdata] [anthropic|gemini]   (vendor defaults to anthropic)
#
# anthropic: needs ANTHROPIC_API_KEY; saves the ended batch object to
#   anthropic-batch-ended.json and its results line to anthropic-result-succeeded.json.
# gemini: needs GEMINI_API_KEY; saves the ended batch operation to gemini-batch-succeeded.json.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
testdata="$(realpath -m "${1:-$repo/packages/agentcore/testdata}")"
vendor="${2:-anthropic}"

field() {
	tr -d '\n' | sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p"
}

record_anthropic() {
	: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set}"
	local batches=https://api.anthropic.com/v1/messages/batches body id batch status

	anthropic() {
		curl -fsS -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
			-H "content-type: application/json" "$@"
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

	printf '%s\n' "$batch" >"$testdata/batch/anthropic-batch-ended.json"
	anthropic "$(field results_url <<<"$batch")" | head -n 1 >"$testdata/batch/anthropic-result-succeeded.json"
	anthropic -X DELETE "$batches/$id" >/dev/null
	echo "recorded batch $id to $testdata/batch/" >&2
}

record_gemini() {
	: "${GEMINI_API_KEY:?GEMINI_API_KEY must be set}"
	local api=https://generativelanguage.googleapis.com/v1beta model=gemini-3.1-flash-lite body name operation state

	gemini() {
		curl -fsS -H "x-goog-api-key: $GEMINI_API_KEY" -H "content-type: application/json" "$@"
	}

	body="$(
		cat <<'JSON'
{"batch":{"display_name":"record-fixtures","input_config":{"requests":{"requests":[{"request":{"contents":[{"role":"user","parts":[{"text":"Reply with the single word: ok"}]}],"generationConfig":{"maxOutputTokens":16000}},"metadata":{"key":"record-fixtures"}}]}}}}
JSON
	)"

	name="$(gemini -X POST --data "$body" "$api/models/$model:batchGenerateContent" | field name)"
	echo "submitted $name" >&2

	while :; do
		operation="$(gemini "$api/$name")"
		state="$(field state <<<"$operation")"
		case "$state" in
		BATCH_STATE_SUCCEEDED | BATCH_STATE_FAILED | BATCH_STATE_CANCELLED | BATCH_STATE_EXPIRED) break ;;
		esac
		echo "$name is $state; polling again in 30s" >&2
		sleep 30
	done

	printf '%s\n' "$operation" >"$testdata/batch/gemini-batch-succeeded.json"
	gemini -X DELETE "$api/$name" >/dev/null
	echo "recorded $name ($state) to $testdata/batch/" >&2
}

mkdir -p "$testdata/batch"
case "$vendor" in
anthropic) record_anthropic ;;
gemini) record_gemini ;;
*)
	echo "unknown vendor: $vendor (want anthropic or gemini)" >&2
	exit 1
	;;
esac
