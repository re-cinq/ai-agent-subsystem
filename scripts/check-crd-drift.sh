#!/usr/bin/env bash
# Fail if deploy/crds has drifted from the agentcore D model.
#
# The CRD YAMLs are generated from the annotated structs in
# packages/agentcore/source/agentcore/crds. Regenerate them with:
#
#   dub build :crdgen
#   ./packages/crdgen/ai-agent-crdgen write-structures deploy/crds
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dub build :crdgen >/dev/null
./packages/crdgen/ai-agent-crdgen write-structures "$tmp" >/dev/null

if diff -ru deploy/crds "$tmp"; then
	echo "deploy/crds is in sync with the agentcore structs."
else
	echo >&2
	echo "ERROR: deploy/crds is out of sync with the D model." >&2
	echo "Regenerate: make regen  (or: ./packages/crdgen/ai-agent-crdgen write-structures deploy/crds)" >&2
	exit 1
fi
