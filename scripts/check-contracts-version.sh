#!/usr/bin/env bash
# Fail if packages/agent-contracts/package.json does not carry the release tag's version.
#
# The npm version is committed rather than derived at publish time (the CHANGELOG
# records it alongside the release), so a release PR that forgets the bump used to
# publish nothing at all: npm rejects the duplicate version and the job's error reads
# like an auth problem. v0.5.0 through v0.7.0 shipped signed images while npm sat on
# 0.3.0 for nine weeks before anyone looked. This turns that silence into a red job
# that names the fix.
#
#   scripts/check-contracts-version.sh v0.8.0
set -euo pipefail

tag="${1:-}"

if [ -z "$tag" ]; then
	echo "usage: $0 <tag>   (e.g. v0.8.0)" >&2
	exit 2
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

pkg="$(node -p "require('./packages/agent-contracts/package.json').version")"

if [ "v$pkg" = "$tag" ]; then
	echo "agent-contracts $pkg matches the release tag $tag."
else
	echo >&2
	echo "ERROR: tag is $tag but packages/agent-contracts/package.json is $pkg." >&2
	echo "Bump it in the release PR, then re-tag:" >&2
	echo "  (cd packages/agent-contracts && npm version ${tag#v} --no-git-tag-version)" >&2
	exit 1
fi
