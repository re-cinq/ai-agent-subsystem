#!/usr/bin/env bash
# Fail if the generated contracts have drifted from the agentcore D model.
#
# packages/agent-contracts/src/types.generated.ts (TypeScript),
# packages/agent-contracts-go/types.generated.go (Go) and the Java types directory
# packages/agent-contracts-java/src/main/java/com/recinq/agentcontracts/types are generated
# from the annotated structs in packages/agentcore/source/agentcore/crds (the same source
# crdgen reads). Regenerate all three with: make regen
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

drifted=0
check() { # check <verb> <committed-file>
	dub run :tsgen -c application -q -- "$1" "$tmp/$(basename "$2")" >/dev/null
	if diff -u "$2" "$tmp/$(basename "$2")"; then
		echo "$2 is in sync with the agentcore structs."
	else
		echo "ERROR: $2 is out of sync with the D model." >&2
		drifted=1
	fi
}

checkDir() { # checkDir <committed-dir>
	dub run :tsgen -c application -q -- emit-java "$tmp/types" >/dev/null
	if diff -ru "$1" "$tmp/types"; then
		echo "$1 is in sync with the agentcore structs."
	else
		echo "ERROR: $1 is out of sync with the D model." >&2
		drifted=1
	fi
}

check emit packages/agent-contracts/src/types.generated.ts
check emit-go packages/agent-contracts-go/types.generated.go
checkDir packages/agent-contracts-java/src/main/java/com/recinq/agentcontracts/types

[ "$drifted" = 0 ] || { echo "Regenerate: make regen" >&2; exit 1; }
