#!/usr/bin/env bash
# Controller integration test on a real (kind) cluster, hermetic — no API key, no
# network in the run pod. It builds the controller + agent images, swaps the agent
# CLI for a deterministic mock, then drives one Agent end to end and asserts the
# controller's behaviour: Job creation with an owner reference, status moving
# Pending -> Running -> Succeeded, status.output/exitCode enriched from the pod,
# and owner-reference garbage collection.
#
#   env: CLUSTER (kind cluster name), KEEP=1 (don't tear down), REBUILD=1 (force
#        image rebuilds), CONTROLLER_IMAGE, AGENT_IMAGE.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

cluster="${CLUSTER:-lore-itest}"
ctx="kind-${cluster}"
controller_image="${CONTROLLER_IMAGE:-ghcr.io/re-cinq/ai-agent-controller:itest}"
agent_image="${AGENT_IMAGE:-ai-agent:dev}"
itest_image="ai-agent:itest"
k() { kubectl --context "$ctx" "$@"; }

have_image() { docker image inspect "$1" >/dev/null 2>&1; }
build() { # build <tag> <dockerfile> <context> [build-args...]
	local tag="$1" file="$2" context="$3"; shift 3
	if [ "${REBUILD:-0}" = 1 ] || ! have_image "$tag"; then
		echo ">> building $tag"
		docker build -t "$tag" -f "$file" "$@" "$context"
	else
		echo ">> reusing $tag"
	fi
}

echo "== build images =="
build "$controller_image" deploy/Dockerfile.controller .
build "$agent_image"      scripts/container/Dockerfile.agent .
build "$itest_image"      scripts/container/Dockerfile.agent-itest scripts/container \
	--build-arg "AGENT_IMAGE=${agent_image}"

echo "== kind cluster $cluster =="
kind get clusters 2>/dev/null | grep -qx "$cluster" || kind create cluster --name "$cluster" --wait 60s
cleanup() { [ "${KEEP:-0}" = 1 ] || kind delete cluster --name "$cluster" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== load images into kind =="
for img in "$controller_image" "$itest_image"; do kind load docker-image "$img" --name "$cluster"; done

echo "== apply CRDs + RBAC + namespace =="
k apply -f deploy/namespace.yaml
k apply -f deploy/crds/
k apply -f deploy/rbac/controller-rbac.yaml
k wait --for condition=Established crd/agents.agents.re-cinq.com \
	crd/stations.agents.re-cinq.com crd/agentdefinitions.agents.re-cinq.com --timeout=60s

echo "== deploy controller (image=$controller_image, AGENT_IMAGE=$itest_image) =="
k apply -f deploy/controller.yaml
k -n ai-agents set image deploy/agent-controller "controller=${controller_image}"
k -n ai-agents set env deploy/agent-controller "AGENT_IMAGE=${itest_image}"
k -n ai-agents patch deploy/agent-controller --type=json \
	-p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
k -n ai-agents rollout status deploy/agent-controller --timeout=90s

echo "== create recipe + station (mock agent) + run =="
k apply -f - <<'YAML'
apiVersion: agents.re-cinq.com/v1alpha1
kind: AgentDefinition
metadata: { name: mock-writer, namespace: ai-agents }
spec:
  model: gpt-mock          # routes to the Codex adapter -> the baked mock `codex`
  prompt: "say hello"
  output: { format: stream-json, sinks: [{ type: stdout }] }
---
apiVersion: agents.re-cinq.com/v1alpha1
kind: Station
metadata: { name: mock-station, namespace: ai-agents }
spec:
  agentDefRef: mock-writer
  deadlineMinutes: 5
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: agent
          image: ai-agent:itest      # has libssl3 for the staged supervisor + the mock
          imagePullPolicy: IfNotPresent
---
apiVersion: agents.re-cinq.com/v1alpha1
kind: Agent
metadata: { name: mock-run, namespace: ai-agents }
spec: { stationRef: mock-station }
YAML

echo "== wait for Agent to reach a terminal phase (<=4m) =="
phase=""
for _ in $(seq 1 48); do
	sleep 5
	phase="$(k -n ai-agents get agent mock-run -o jsonpath='{.status.phase}' 2>/dev/null || true)"
	echo "   phase=${phase:-<none>}"
	case "$phase" in Succeeded|Failed) break;; esac
done

fail() { echo "FAIL: $1"; k -n ai-agents get agent mock-run -o yaml | sed -n '/^status:/,$p'; exit 1; }

echo "== assertions =="
[ "$phase" = "Succeeded" ] || fail "agent phase is '$phase', expected Succeeded"

job="$(k -n ai-agents get agent mock-run -o jsonpath='{.status.jobName}')"
[ "$job" = "agent-job-mock-run" ] || fail "jobName '$job'"
owner="$(k -n ai-agents get job "$job" -o jsonpath='{.metadata.ownerReferences[0].controller}')"
[ "$owner" = "true" ] || fail "job ownerReference controller=$owner"

exit_code="$(k -n ai-agents get agent mock-run -o jsonpath='{.status.exitCode}')"
[ "$exit_code" = "0" ] || fail "status.exitCode=$exit_code"
output="$(k -n ai-agents get agent mock-run -o jsonpath='{.status.output}')"
echo "$output" | grep -q "hello from the mock agent" || fail "status.output missing the agent's events"
echo "  PASS  Pending -> Running -> Succeeded, owned Job, status.output + exitCode enriched"

echo "== owner-reference GC: deleting the Agent removes its Job =="
k -n ai-agents delete agent mock-run --wait=true
sleep 3
k -n ai-agents get job "$job" >/dev/null 2>&1 && fail "Job not garbage-collected" || true
echo "  PASS  Job garbage-collected via ownerReference"

echo "ALL PASSED"
