#!/usr/bin/env bash
# Start one Agent run against a Station. Usage:
#   examples/run-agent.sh <station> [key=value ...]
# Example:
#   examples/run-agent.sh story-writer title="The Last Lighthouse"
#
# Each invocation creates a fresh Agent (generateName -> unique run id) in the
# ai-agents namespace and prints the run id. Watch it with:
#   kubectl -n ai-agents get agents -w
# Targets the current kubectl context unless KUBE_CONTEXT names another one.
set -euo pipefail

ns="${AGENT_NAMESPACE:-ai-agents}"
kube() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }
echo "context=${KUBE_CONTEXT:-$(kubectl config current-context)} namespace=${ns}" >&2

[ $# -ge 1 ] || { echo "usage: $0 <station> [key=value ...]" >&2; exit 2; }
station="$1"; shift

params=""
for kv in "$@"; do
  [[ "$kv" == *=* ]] || { echo "bad param '$kv' (expected key=value)" >&2; exit 2; }
  params+="$(printf '    %s: "%s"' "${kv%%=*}" "${kv#*=}")"$'\n'
done
[ -n "$params" ] || params=$'    {}'

kube -n "$ns" create -f - <<EOF
apiVersion: agents.re-cinq.com/v1beta1
kind: Agent
metadata:
  generateName: ${station}-run-
spec:
  stationRef: ${station}
  parameters:
${params}
EOF
