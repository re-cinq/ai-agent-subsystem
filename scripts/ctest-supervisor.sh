#!/usr/bin/env bash
# Cross-distro supervisor test: build the supervisor + mock agent + integration
# runner once on Rocky 9 (the oldest glibc + openssl 3 among the glibc Kubernetes
# base distros, so one build runs on all of them), then run the real itest suite
# inside each target distro — carrying the ldc runtime libs and installing libssl3
# where the base image lacks it. The supervisor requires glibc, so Alpine/musl is
# intentionally not a target.
#
#   TARGETS="debian:bookworm-slim" ./scripts/ctest-supervisor.sh    # a subset
#   CONTAINER_ENGINE=podman ./scripts/ctest-supervisor.sh
#   BUILD_ONLY=1 STAGE_DIR=stage ./scripts/ctest-supervisor.sh     # stage the stack, skip tests
#   SKIP_BUILD=1 STAGE_DIR=stage ./scripts/ctest-supervisor.sh     # test a prebuilt stack
#
# CI (supervisor-container.yml) calls this same script: BUILD_ONLY in its build
# job, SKIP_BUILD per matrix distro.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

engine="${CONTAINER_ENGINE:-docker}"
builder="${BUILDER_IMAGE:-rockylinux:9}"
targets="${TARGETS:-rockylinux:9 amazonlinux:2023 debian:bookworm-slim ubuntu:24.04}"

if [ -n "${STAGE_DIR:-}" ]; then
  mkdir -p "$STAGE_DIR"
  stage="$(cd "$STAGE_DIR" && pwd)"
else
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage" 2>/dev/null || true' EXIT
fi

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  echo ">> building supervisor stack on $builder"
  "$engine" run --rm -v "$PWD:/src" -w /src -v "$stage:/out" "$builder" sh -euc '
    dnf install -y epel-release >/dev/null
    dnf install -y ldc dub gcc git openssl-devel zlib-devel >/dev/null
    for pkg in supervisor mockagent itest; do dub build :$pkg --compiler=ldc2; done
    cp packages/supervisor/ai-agent-supervisor packages/mockagent/ai-agent-mock packages/itest/ai-agent-itest /out/
    cp /usr/lib64/libphobos2-ldc-shared.so.* /usr/lib64/libdruntime-ldc-shared.so.* /out/
  '
fi
chmod +x "$stage"/ai-agent-* 2>/dev/null || true

if [ "${BUILD_ONLY:-0}" = 1 ]; then
  echo ">> build-only: supervisor stack staged in $stage"
  exit 0
fi

fail=0
for img in $targets; do
  echo ">> $img"
  "$engine" run --rm \
    -v "$stage:/opt/sup:ro" \
    -v "$PWD/scripts/container/run-itest.sh:/run-itest.sh:ro" \
    "$img" /run-itest.sh || { echo "<<< $img FAILED >>>"; fail=1; }
done

[ "$fail" -eq 0 ] && echo "ALL DISTROS PASSED" || echo "SOME DISTROS FAILED"
exit "$fail"
