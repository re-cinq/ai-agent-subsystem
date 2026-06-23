#!/usr/bin/env bash
# Controller integration test on a real cluster (kind or minikube), hermetic — no API key, no
# network in the run pod. It builds the controller + agent images, swaps the agent
# CLI for a deterministic mock, then drives Agents end to end through two scenarios:
#   A) controller wiring: Job creation with an owner reference, status moving
#      Pending -> Running -> Succeeded, status.output/exitCode enriched from the pod,
#      and owner-reference garbage collection.
#   B) credential path: an `agent-secrets` Secret -> ANTHROPIC_API_KEY env var (via
#      secretKeyRef) reaches the agent child (kubelet -> pod -> supervisor -> child),
#      proven with a fake key the mock asserts before it Succeeds.
#   C) scale (opt-in, LOAD=<N>): drive N Agents through one Station and assert they all
#      reach Succeeded while the controller stays Ready — exercises the informer-cache
#      reconcile loop at hundreds of Agents. Off unless LOAD is set; needs pod capacity.
#
#   env: CLUSTER_TOOL (kind|minikube, default kind), CLUSTER (cluster/profile name),
#        KEEP=1 (don't tear down), REBUILD=1 (force image rebuilds), LOAD=<N> (run
#        Scenario C with N Agents), CONTROLLER_IMAGE, AGENT_IMAGE. Use minikube on
#        hosts where kind's containerd OOMs the init.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

cluster="${CLUSTER:-lore-itest}"
cluster_tool="${CLUSTER_TOOL:-kind}"
controller_image="${CONTROLLER_IMAGE:-ghcr.io/re-cinq/ai-agent-controller:itest}"
agent_image="${AGENT_IMAGE:-ai-agent:dev}"
itest_image="ai-agent:itest"

case "$cluster_tool" in
	kind) ctx="kind-${cluster}" ;;
	minikube) ctx="$cluster" ;;
	*) echo "unsupported CLUSTER_TOOL '$cluster_tool' (kind|minikube)"; exit 2 ;;
esac
k() { kubectl --context "$ctx" "$@"; }

# Only cluster lifecycle and image side-loading differ by backend; the whole test
# body below is identical. minikube's docker runtime is the escape hatch on hosts
# where kind's containerd balloons the init container's memory and OOM-kills it.
cluster_ensure() {
	case "$cluster_tool" in
		kind) kind get clusters 2>/dev/null | grep -qx "$cluster" || kind create cluster --name "$cluster" --wait 60s ;;
		minikube) minikube -p "$cluster" status >/dev/null 2>&1 || minikube -p "$cluster" start ;;
	esac
}
cluster_destroy() {
	case "$cluster_tool" in
		kind) kind delete cluster --name "$cluster" >/dev/null 2>&1 || true ;;
		minikube) minikube -p "$cluster" delete >/dev/null 2>&1 || true ;;
	esac
}
image_load() { # image_load <tag>
	case "$cluster_tool" in
		kind) kind load docker-image "$1" --name "$cluster" ;;
		minikube) minikube -p "$cluster" image load "$1" ;;
	esac
}

# Dump the current scenario's Agent status, then abort. `agent` is set per scenario.
fail() { echo "FAIL: $1"; k -n ai-agents get agent "$agent" -o yaml | sed -n '/^status:/,$p'; exit 1; }

# Poll an Agent until it reaches a terminal phase (<=4m). Progress goes to stderr;
# the final phase is echoed to stdout so the caller can capture it.
wait_terminal() { # wait_terminal <agent>
	local name="$1" phase=""
	for _ in $(seq 1 48); do
		sleep 5
		phase="$(k -n ai-agents get agent "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
		echo "   phase=${phase:-<none>}" >&2
		case "$phase" in Succeeded | Failed) break ;; esac
	done
	echo "$phase"
}

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

echo "== $cluster_tool cluster $cluster =="
cluster_ensure
cleanup() { [ "${KEEP:-0}" = 1 ] || cluster_destroy; }
trap cleanup EXIT

echo "== load images into $cluster_tool =="
for img in "$controller_image" "$itest_image"; do image_load "$img"; done

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

echo "== Scenario A: controller wiring (mock agent, no secret) =="
agent=mock-run
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

echo "== wait for $agent to reach a terminal phase (<=4m) =="
phase="$(wait_terminal "$agent")"

echo "== assertions =="
[ "$phase" = "Succeeded" ] || fail "agent phase is '$phase', expected Succeeded"

job="$(k -n ai-agents get agent "$agent" -o jsonpath='{.status.jobName}')"
[ "$job" = "agent-job-mock-run" ] || fail "jobName '$job'"
owner="$(k -n ai-agents get job "$job" -o jsonpath='{.metadata.ownerReferences[0].controller}')"
[ "$owner" = "true" ] || fail "job ownerReference controller=$owner"

exit_code="$(k -n ai-agents get agent "$agent" -o jsonpath='{.status.exitCode}')"
[ "$exit_code" = "0" ] || fail "status.exitCode=$exit_code"
output="$(k -n ai-agents get agent "$agent" -o jsonpath='{.status.output}')"
echo "$output" | grep -q "hello from the mock agent" || fail "status.output missing the agent's events"
echo "  PASS  Pending -> Running -> Succeeded, owned Job, status.output + exitCode enriched"

echo "== owner-reference GC: deleting the Agent removes its Job =="
k -n ai-agents delete agent "$agent" --wait=true
sleep 3
k -n ai-agents get job "$job" >/dev/null 2>&1 && fail "Job not garbage-collected" || true
echo "  PASS  Job garbage-collected via ownerReference"

echo "== Scenario B: credential path (agent-secrets -> ANTHROPIC_API_KEY -> agent child) =="
# Prove the production credential chain end to end with a FAKE key and no network:
# the controller injects ANTHROPIC_API_KEY from the `agent-secrets` Secret via
# secretKeyRef, the kubelet resolves it, the supervisor inherits it and passes it to
# the agent child. The mock `codex` (LORE_EXPECT_API_KEY set below) exits non-zero
# unless the value it sees equals the one the Secret carried, so Succeeded proves the
# whole chain. Cross-channel by design: LORE_EXPECT_API_KEY arrives as a literal env,
# ANTHROPIC_API_KEY via the Secret -> equality is a real check, not a tautology. Keep
# model gpt-mock: a real claude-* model would make the init container install the real
# CLI from the network, breaking hermeticity.
agent=secret-run
fake_key=sk-ant-itest-FAKE-9f3a
k -n ai-agents create secret generic agent-secrets --from-literal=ANTHROPIC_API_KEY="$fake_key"
k apply -f - <<YAML
apiVersion: agents.re-cinq.com/v1alpha1
kind: AgentDefinition
metadata: { name: secret-writer, namespace: ai-agents }
spec:
  model: gpt-mock
  prompt: "say hello"
  resources:
    secrets: [{ name: ANTHROPIC_API_KEY, ref: ANTHROPIC_API_KEY }]
    env: [{ name: LORE_EXPECT_API_KEY, value: $fake_key }]
  output: { format: stream-json, sinks: [{ type: stdout }] }
---
apiVersion: agents.re-cinq.com/v1alpha1
kind: Station
metadata: { name: secret-station, namespace: ai-agents }
spec:
  agentDefRef: secret-writer
  deadlineMinutes: 5
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: agent
          image: ai-agent:itest    # no ~/.claude mount: auth must come only from the Secret
          imagePullPolicy: IfNotPresent
---
apiVersion: agents.re-cinq.com/v1alpha1
kind: Agent
metadata: { name: secret-run, namespace: ai-agents }
spec: { stationRef: secret-station }
YAML

echo "== wait for $agent to reach a terminal phase (<=4m) =="
phase="$(wait_terminal "$agent")"

echo "== assertions =="
# Succeeded is reachable only if the exact fake key reached the agent child; the mock
# exits 7 (-> Failed) on an unset or mismatched ANTHROPIC_API_KEY.
[ "$phase" = "Succeeded" ] || fail "agent phase is '$phase', expected Succeeded (injected ANTHROPIC_API_KEY did not reach the agent child)"
exit_code="$(k -n ai-agents get agent "$agent" -o jsonpath='{.status.exitCode}')"
[ "$exit_code" = "0" ] || fail "status.exitCode=$exit_code (mock exits 7 on a missing/wrong key)"
output="$(k -n ai-agents get agent "$agent" -o jsonpath='{.status.output}')"
echo "$output" | grep -q "hello from the mock agent" || fail "status.output missing the agent's events"
job="$(k -n ai-agents get agent "$agent" -o jsonpath='{.status.jobName}')"
owner="$(k -n ai-agents get job "$job" -o jsonpath='{.metadata.ownerReferences[0].controller}')"
[ "$owner" = "true" ] || fail "job ownerReference controller=$owner"
echo "  PASS  agent-secrets -> ANTHROPIC_API_KEY reached the agent child; run Succeeded"

# Scenario C: scale. Opt-in (LOAD=<N>), not run in CI — it needs a cluster with the
# pod capacity to drain N run pods. Proves the watch + cache reconcile loop drives
# hundreds of Agents to terminal without the controller falling over: the watch
# resumes from resourceVersion (no full replay per reconnect) and concurrency/pruning
# read the cache instead of re-listing per reconcile, while a ~15s poll lists once and
# reconciles all as the safety net. History limits are set high so terminal Agents are
# not pruned out from under the terminal-count below.
if [ "${LOAD:-0}" -gt 0 ]; then
	load_n="${LOAD}"
	echo "== Scenario C: load — ${load_n} Agents through one Station (opt-in) =="
	k apply -f - <<'YAML'
apiVersion: agents.re-cinq.com/v1alpha1
kind: AgentDefinition
metadata: { name: load-writer, namespace: ai-agents }
spec:
  model: gpt-mock
  prompt: "say hello"
  output: { format: stream-json, sinks: [{ type: stdout }] }
---
apiVersion: agents.re-cinq.com/v1alpha1
kind: Station
metadata: { name: load-station, namespace: ai-agents }
spec:
  agentDefRef: load-writer
  deadlineMinutes: 5
  successfulRunsHistoryLimit: 100000
  failedRunsHistoryLimit: 100000
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: agent
          image: ai-agent:itest
          imagePullPolicy: IfNotPresent
YAML

	echo "== create ${load_n} Agents =="
	for i in $(seq 1 "$load_n"); do
		printf 'apiVersion: agents.re-cinq.com/v1alpha1\nkind: Agent\nmetadata: { name: load-%s, namespace: ai-agents }\nspec: { stationRef: load-station }\n---\n' "$i"
	done | k apply -f - >/dev/null
	echo "  created ${load_n} Agents"

	load_phases() {
		k -n ai-agents get agents \
			-o jsonpath='{range .items[?(@.spec.stationRef=="load-station")]}{.status.phase}{"\n"}{end}'
	}
	# maxConcurrentRuns is unset, so throughput is bounded only by the cluster's pod
	# capacity; budget generously and scale with N.
	deadline=$(( load_n * 6 + 180 ))
	start=$SECONDS
	while :; do
		terminal="$(load_phases | grep -cE 'Succeeded|Failed' || true)"
		echo "   terminal=${terminal}/${load_n} (t=$((SECONDS - start))s)" >&2
		[ "$terminal" -ge "$load_n" ] && break
		[ $((SECONDS - start)) -ge "$deadline" ] && { echo "FAIL: only ${terminal}/${load_n} terminal after ${deadline}s"; exit 1; }
		sleep 5
	done

	failed="$(load_phases | grep -c 'Failed' || true)"
	[ "$failed" = "0" ] || { echo "FAIL: ${failed} load Agents reached Failed"; exit 1; }

	# The controller must have stayed Ready throughout — no crash/restart under load.
	ready="$(k -n ai-agents get pods -l agents.re-cinq.com/component=controller -o jsonpath='{.items[*].status.containerStatuses[0].ready}')"
	echo "$ready" | grep -q false && { echo "FAIL: a controller pod is not Ready"; exit 1; } || true
	restarts="$(k -n ai-agents get pods -l agents.re-cinq.com/component=controller -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}')"
	echo "  PASS  ${load_n} Agents all Succeeded; controller Ready, restartCounts=[${restarts}]"
fi

echo "ALL PASSED"
