#!/usr/bin/env bash
# Fail if the generated TypeScript contracts have drifted from the agentcore D model.
#
# packages/agent-contracts/src/types.generated.ts is generated from the annotated
# structs in packages/agentcore/source/agentcore/crds (the same source crdgen reads).
# Regenerate with:
#
#   dub run :tsgen -c application -- emit packages/agent-contracts/src/types.generated.ts
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

dub run :tsgen -c application -q -- emit "$tmp" >/dev/null

if diff -u packages/agent-contracts/src/types.generated.ts "$tmp"; then
	echo "agent-contracts types are in sync with the agentcore structs."
else
	echo >&2
	echo "ERROR: packages/agent-contracts/src/types.generated.ts is out of sync with the D model." >&2
	echo "Regenerate: make regen  (or: dub run :tsgen -c application -- emit packages/agent-contracts/src/types.generated.ts)" >&2
	exit 1
fi
