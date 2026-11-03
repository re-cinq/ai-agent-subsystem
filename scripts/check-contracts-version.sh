#!/usr/bin/env bash
# Fail if any contract package (npm, Java, Python, Rust, .NET) does not carry the release
# tag's version.
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

# The version each package publishes, as `<file> <version>` lines. Each read takes the
# project's own version: the first match, before any dependency versions.
versions() {
	echo "packages/agent-contracts/package.json $(node -p "require('./packages/agent-contracts/package.json').version")"
	echo "packages/agent-contracts-java/pom.xml $(sed -n 's#^  <version>\(.*\)</version>#\1#p' packages/agent-contracts-java/pom.xml | head -1)"
	echo "packages/agent-contracts-python/pyproject.toml $(sed -n 's#^version = "\(.*\)"#\1#p' packages/agent-contracts-python/pyproject.toml | head -1)"
	echo "packages/agent-contracts-rust/Cargo.toml $(sed -n 's#^version = "\(.*\)"#\1#p' packages/agent-contracts-rust/Cargo.toml | head -1)"
	csproj=packages/agent-contracts-dotnet/src/ReCinq.AgentContracts/ReCinq.AgentContracts.csproj
	echo "$csproj $(sed -n 's#.*<Version>\(.*\)</Version>.*#\1#p' "$csproj" | head -1)"
}

mismatch=0
while read -r file version; do
	if [ "v$version" = "$tag" ]; then
		echo "$file is $version, matching the release tag $tag."
	else
		echo "ERROR: tag is $tag but $file is $version." >&2
		mismatch=1
	fi
done < <(versions)

if [ "$mismatch" = 1 ]; then
	echo >&2
	echo "Bump every contract package in the release PR, then re-tag:" >&2
	echo "  scripts/bump-contracts-version.sh ${tag#v}" >&2
fi
exit "$mismatch"
