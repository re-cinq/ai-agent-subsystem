# Shared cluster helpers for the scripts that drive a real cluster: the controller
# integration test and the demo. Source it after `cd`-ing to the repo root.
#
#   env: CLUSTER_TOOL (kind|minikube, default kind), CLUSTER (cluster/profile name,
#        default agent-itest), KEEP=1 (don't tear down), REBUILD=1 (force image
#        rebuilds), CONTROLLER_IMAGE, AGENT_IMAGE. Use minikube on hosts where kind's
#        containerd OOMs the init.

cluster="${CLUSTER:-agent-itest}"
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

# Only cluster lifecycle and image side-loading differ by backend; everything else is
# identical. minikube's docker runtime is the escape hatch on hosts where kind's
# containerd balloons the init container's memory and OOM-kills it.
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

# Dump the current scenario's Agent status, then abort. `agent` is set by the caller.
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

# Build the images, bring the cluster up, and deploy CRDs, RBAC and the controller
# from deploy/. The controller injects <injected-agent-image> into every run pod:
# the mock image for hermetic runs, the real agent image for live ones.
install_subsystem() { # install_subsystem <injected-agent-image>
	local injected="$1"

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
	for img in "$controller_image" "$injected"; do image_load "$img"; done

	echo "== apply CRDs + RBAC + namespace =="
	k apply -f deploy/namespace.yaml
	k apply -f deploy/crds/
	k apply -f deploy/rbac/controller-rbac.yaml
	k wait --for condition=Established crd/agents.agents.re-cinq.com \
		crd/stations.agents.re-cinq.com crd/agentdefinitions.agents.re-cinq.com --timeout=60s

	echo "== deploy controller (image=$controller_image, AGENT_IMAGE=$injected) =="
	k apply -f deploy/controller.yaml
	k -n ai-agents set image deploy/agent-controller "controller=${controller_image}"
	k -n ai-agents set env deploy/agent-controller "AGENT_IMAGE=${injected}"
	k -n ai-agents patch deploy/agent-controller --type=json \
		-p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
	k -n ai-agents rollout status deploy/agent-controller --timeout=90s
}
