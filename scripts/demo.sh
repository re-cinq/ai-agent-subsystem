#!/usr/bin/env bash
# One-command demo, and the CI gate that keeps examples/ working. It brings up a local
# cluster, installs the subsystem from deploy/, then for each example:
#   1. server-side dry-runs the manifests (schema check: catches renamed or removed fields),
#   2. applies them,
#   3. runs the example's own documented `examples/run-agent.sh ...` header line,
#   4. waits for the Agent and asserts Succeeded with a non-empty status.output.
# An example with no run-agent.sh line in its header is schema-checked only.
#
# With ANTHROPIC_API_KEY set, runs call the real model. With MOCK=1, or no key, every
# AgentDefinition is patched to `model: gpt-mock` and every Station to the ai-agent:itest
# image, so runs are hermetic (no key, no network in the run pod).
#
#   env: EXAMPLES ("all", or space-separated names from examples/*.yaml; default
#        story-writer), MOCK=1, plus scripts/lib/cluster.sh's CLUSTER_TOOL, CLUSTER
#        (default agent-demo), KEEP, REBUILD.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
CLUSTER="${CLUSTER:-agent-demo}"
# shellcheck source=lib/cluster.sh
. scripts/lib/cluster.sh

mock="${MOCK:-0}"
[ -n "${ANTHROPIC_API_KEY:-}" ] || mock=1
api_key="${ANTHROPIC_API_KEY:-sk-ant-demo-mock}"

examples="${EXAMPLES:-story-writer}"
[ "$examples" = all ] && examples="$(basename -s .yaml examples/*.yaml | tr '\n' ' ')"

if [ "$mock" = 1 ]; then
	echo "== mock mode: hermetic runs (no ANTHROPIC_API_KEY, or MOCK=1) =="
	install_subsystem "$itest_image"
else
	install_subsystem "$agent_image"
fi

k -n ai-agents create secret generic agent-secrets \
	--from-literal=ANTHROPIC_API_KEY="$api_key" --dry-run=client -o yaml | k apply -f -

# Point every recipe in <file> at the mock model and every runtime at the mock image.
# The agent container is the first one in each example Station.
use_mock() { # use_mock <file>
	local resource
	for resource in $(k get -f "$1" -o name); do
		case "$resource" in
			agentdefinition*) k -n ai-agents patch "$resource" --type=merge -p '{"spec":{"model":"gpt-mock"}}' ;;
			station*) k -n ai-agents patch "$resource" --type=json -p "[
				{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${itest_image}\"},
				{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"IfNotPresent\"}]" ;;
		esac
	done
}

export KUBE_CONTEXT="$ctx"
passed=0
for name in $examples; do
	file="examples/${name}.yaml"
	[ -f "$file" ] || { echo "FAIL: no such example '$file'"; exit 1; }

	echo "== $name: schema check (server-side dry-run) =="
	k apply --dry-run=server --validate=strict -f "$file"

	run_line="$(sed -n 's/^#[[:space:]]*\(examples\/run-agent\.sh .*\)$/\1/p' "$file" | head -1)"
	if [ -z "$run_line" ]; then
		echo "  PASS  $name (schema only: no run-agent.sh line in its header)"
		passed=$((passed + 1))
		continue
	fi

	echo "== $name: apply and run: $run_line =="
	k apply -f "$file"
	[ "$mock" = 1 ] && use_mock "$file"
	created="$(eval "$run_line")"
	agent="${created%% *}"
	agent="${agent#*/}"

	phase="$(wait_terminal "$agent")"
	[ "$phase" = "Succeeded" ] || fail "$name: agent phase is '$phase', expected Succeeded"
	output="$(k -n ai-agents get agent "$agent" -o jsonpath='{.status.output}')"
	[ -n "$output" ] || fail "$name: status.output is empty"
	if [ "$mock" = 1 ]; then
		echo "$output" | grep -q "hello from the mock agent" || fail "$name: status.output missing the agent's events"
	fi
	echo "  PASS  $name -> $agent Succeeded"
	echo "$output"
	passed=$((passed + 1))
done

echo "== demo: $passed example(s) passed =="
