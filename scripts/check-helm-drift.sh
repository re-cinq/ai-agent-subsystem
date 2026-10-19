#!/usr/bin/env bash
# Fail if the Helm chart renders different objects than deploy/.
#
# deploy/ is the source of truth (ADR-004); deploy/helm/ai-agent-subsystem is a
# packaging of it. For the default values and for each toggle, this renders
# `helm template` and `kubectl kustomize` (deploy/ plus the matching
# deploy/components/*), normalises both to sorted documents with sorted keys,
# and diffs them. List order is kept: env and ports order is part of the render.
#
#   scripts/check-helm-drift.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
chart="$repo/deploy/helm/ai-agent-subsystem"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

normalize() { # normalize <file> -> sorted documents on stdout
	python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
key = lambda d: (d["kind"], d["metadata"].get("namespace", ""), d["metadata"]["name"])
print("---\n".join(yaml.safe_dump(d, sort_keys=True) for d in sorted(docs, key=key)), end="")
' "$1"
}

relative() { # relative <path> <from-dir> -> path relative to from-dir (kustomize refuses absolute ones)
	python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"
}

kustomize_with() { # kustomize_with <component>... -> deploy/ plus those components
	local overlay="$tmp/overlay"
	rm -rf "$overlay" && mkdir -p "$overlay"
	{
		echo "apiVersion: kustomize.config.k8s.io/v1beta1"
		echo "kind: Kustomization"
		echo "resources: [$(relative "$repo/deploy" "$overlay")]"
		echo "components:"
		for component in "$@"; do
			echo "  - $(relative "$repo/deploy/components/$component" "$overlay")"
		done
	} >"$overlay/kustomization.yaml"
	kubectl kustomize "$overlay"
}

failed=0
check() { # check <label> "<helm --set flags>" <component>...
	local label="$1" sets="$2"
	shift 2
	# shellcheck disable=SC2086 # sets is a deliberate word list
	helm template ai-agent-subsystem "$chart" --include-crds $sets >"$tmp/helm.yaml"
	if [ "$#" -eq 0 ]; then
		kubectl kustomize "$repo/deploy" >"$tmp/kustomize.yaml"
	else
		kustomize_with "$@" >"$tmp/kustomize.yaml"
	fi
	if diff -u --label "kubectl kustomize ($label)" --label "helm template ($label)" \
		<(normalize "$tmp/kustomize.yaml") <(normalize "$tmp/helm.yaml"); then
		echo "helm chart matches deploy/ ($label)."
	else
		failed=1
	fi
}

check defaults ""
check batch "--set batch.enabled=true" batch
check model-catalog "--set modelCatalog.enabled=true" model-catalog
check realtime "--set realtime.enabled=true" realtime
check webhooks "--set webhooks.enabled=true" webhooks
check all "--set batch.enabled=true --set modelCatalog.enabled=true --set realtime.enabled=true --set webhooks.enabled=true" \
	batch model-catalog realtime webhooks

if [ "$failed" -ne 0 ]; then
	echo >&2
	echo "ERROR: deploy/helm/ai-agent-subsystem has drifted from deploy/." >&2
	echo "Mirror the deploy/ change into the chart's templates/ (or crds/: make regen)." >&2
	exit 1
fi
