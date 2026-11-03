#!/usr/bin/env bash
# Set every contract package to one version, for the release PR:
#
#   scripts/bump-contracts-version.sh 0.16.0
#
# Edits only each package's own version line, so formatting elsewhere in the files is untouched.
# scripts/check-contracts-version.sh fails the release tag when any of them disagrees.
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "usage: $0 <version>   (e.g. 0.16.0)" >&2
	exit 2
fi

cd "$(dirname "$0")/.."

sed -i "0,/\"version\": \".*\"/s//\"version\": \"$version\"/" packages/agent-contracts/package.json
sed -i "0,/^  <version>.*<\/version>/s//  <version>$version<\/version>/" packages/agent-contracts-java/pom.xml
sed -i "0,/^version = \".*\"/s//version = \"$version\"/" packages/agent-contracts-python/pyproject.toml
sed -i "0,/^version = \".*\"/s//version = \"$version\"/" packages/agent-contracts-rust/Cargo.toml
sed -i "0,/<Version>.*<\/Version>/s//<Version>$version<\/Version>/" \
	packages/agent-contracts-dotnet/src/ReCinq.AgentContracts/ReCinq.AgentContracts.csproj

./scripts/check-contracts-version.sh "v$version"
