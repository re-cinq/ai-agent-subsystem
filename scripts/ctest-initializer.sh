#!/usr/bin/env bash
# Container integration test: build a minimal image where git/curl are absent and
# run ai-agent-init inside it, verifying the real package-manager self-bootstrap
# path that the host itest can't reach. Defaults to Debian/apt; override the base
# images for another distro, e.g. Fedora/dnf:
#
#   BUILDER_IMAGE=fedora:40 RUNTIME_IMAGE=fedora:40 ./scripts/ctest-initializer.sh
#
# Set CTEST_CLAUDE=1 to also run the real Claude installer (needs network to
# claude.ai). CONTAINER_ENGINE overrides docker (e.g. podman).
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

engine="${CONTAINER_ENGINE:-docker}"
builder="${BUILDER_IMAGE:-debian:bookworm}"
runtime="${RUNTIME_IMAGE:-debian:bookworm-slim}"
tag="ai-agent-init-ctest"

"$engine" build \
	--build-arg "BUILDER_IMAGE=$builder" \
	--build-arg "RUNTIME_IMAGE=$runtime" \
	-f scripts/container/Dockerfile \
	-t "$tag" .

"$engine" run --rm -e "CTEST_CLAUDE=${CTEST_CLAUDE:-0}" "$tag"
