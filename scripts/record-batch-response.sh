#!/usr/bin/env bash
# Record a real batch API round trip into <testdata>/batch/ (default testdata:
# packages/agentcore/testdata): submit a one-request batch with the body the vendor's
# batch/<vendor>.d requestBody builds, poll every 30s until it ends, save what it ended
# with, then delete the batch. The run costs one small call at the batch price and can
# take minutes.
#
# Usage: record-batch-response.sh [testdata] [anthropic|gemini|openai]   (vendor defaults to anthropic)
#
# anthropic: needs ANTHROPIC_API_KEY; saves the ended batch object to
#   anthropic-batch-ended.json and its results line to anthropic-result-succeeded.json.
# gemini: needs GEMINI_API_KEY; saves the ended batch operation to gemini-batch-succeeded.json.
# openai: needs OPENAI_API_KEY; uploads the one-line input file, saves the ended batch object to
#   openai-batch-completed.json and its output file's line to openai-output-succeeded.json,
#   then deletes both files (a batch object cannot be deleted).
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

record_openai() {
	: "${OPENAI_API_KEY:?OPENAI_API_KEY must be set}"
	local api=https://api.openai.com/v1 input file batch_id batch status output

	openai() {
		curl -fsS -H "authorization: Bearer $OPENAI_API_KEY" "$@"
	}

	input="$(mktemp --suffix=.jsonl)"
	cat >"$input" <<'JSON'
{"custom_id":"record-fixtures","method":"POST","url":"/v1/responses","body":{"model":"gpt-5-mini","input":"Reply with the single word: ok","max_output_tokens":16000}}
JSON
	file="$(openai -F purpose=batch -F "file=@$input;type=application/jsonl" "$api/files" | field id)"
	rm -f "$input"
	batch_id="$(openai -H "content-type: application/json" -X POST \
		--data "{\"input_file_id\":\"$file\",\"endpoint\":\"/v1/responses\",\"completion_window\":\"24h\"}" \
		"$api/batches" | field id)"
	echo "submitted $batch_id over $file" >&2

	while :; do
		batch="$(openai "$api/batches/$batch_id")"
		status="$(field status <<<"$batch")"
		case "$status" in
		completed | failed | expired | cancelled) break ;;
		esac
		echo "$batch_id is $status; polling again in 30s" >&2
		sleep 30
	done

	printf '%s\n' "$batch" >"$testdata/batch/openai-batch-completed.json"
	output="$(field output_file_id <<<"$batch")"
	if [ -n "$output" ]; then
		openai "$api/files/$output/content" | head -n 1 >"$testdata/batch/openai-output-succeeded.json"
		openai -X DELETE "$api/files/$output" >/dev/null
	fi
	openai -X DELETE "$api/files/$file" >/dev/null
	echo "recorded $batch_id ($status) to $testdata/batch/" >&2
}

mkdir -p "$testdata/batch"
case "$vendor" in
anthropic) record_anthropic ;;
gemini) record_gemini ;;
openai) record_openai ;;
*)
	echo "unknown vendor: $vendor (want anthropic, gemini or openai)" >&2
	exit 1
	;;
esac
