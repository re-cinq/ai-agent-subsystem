#!/usr/bin/env bash
# Cross-distro init-container test: build ai-agent-init once on an old-glibc base
# (debian:bullseye, glibc 2.31 — druntime/phobos static, glibc dynamic), then run
# the real binary against a throwaway origin repo on each glibc distro used as a
# Kubernetes base image. Alpine is musl, so it builds + tests natively instead of
# reusing the staged binary. CI (init-container.yml) calls this same script.
#
#   TARGETS="debian:bookworm-slim" ./scripts/ctest-init-portable.sh    # a subset
#   TARGETS="alpine:3.20" ./scripts/ctest-init-portable.sh             # musl only
#   BUILD_ONLY=1 STAGE_DIR=stage ./scripts/ctest-init-portable.sh     # stage the binary, skip tests
#   SKIP_BUILD=1 STAGE_DIR=stage ./scripts/ctest-init-portable.sh     # test a prebuilt binary
#   CONTAINER_ENGINE=podman ./scripts/ctest-init-portable.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

engine="${CONTAINER_ENGINE:-docker}"
builder="${BUILDER_IMAGE:-debian:bullseye}"
targets="${TARGETS:-debian:bookworm-slim ubuntu:24.04 rockylinux:9 amazonlinux:2023 alpine:3.20}"

work="$(mktemp -d)"
trap 'rm -rf "$work" 2>/dev/null || true' EXIT

if [ -n "${STAGE_DIR:-}" ]; then
	mkdir -p "$STAGE_DIR"
	stage="$(cd "$STAGE_DIR" && pwd)"
else
	stage="$work/stage"
	mkdir -p "$stage"
fi

glibc_targets=""
musl_targets=""
for img in $targets; do
	case "$img" in
	alpine*) musl_targets="$musl_targets $img" ;;
	*) glibc_targets="$glibc_targets $img" ;;
	esac
done

if [ -n "$glibc_targets" ] || [ "${BUILD_ONLY:-0}" = 1 ]; then
	if [ "${SKIP_BUILD:-0}" != 1 ]; then
		echo ">> building portable ai-agent-init on $builder"
		"$engine" run --rm -v "$PWD:/src" -w /src "$builder" sh -euc '
			export DEBIAN_FRONTEND=noninteractive
			apt-get update >/dev/null
			apt-get install -y --no-install-recommends ldc dub gcc libc6-dev zlib1g-dev >/dev/null
			DFLAGS="-link-defaultlib-shared=false -L-lz" dub build :initializer --compiler=ldc2
		'
		cp packages/initializer/ai-agent-init "$stage/ai-agent-init"
	fi
	chmod +x "$stage/ai-agent-init" 2>/dev/null || true
fi

if [ "${BUILD_ONLY:-0}" = 1 ]; then
	echo ">> build-only: ai-agent-init staged in $stage"
	exit 0
fi

fail=0

if [ -n "$glibc_targets" ]; then
	origin="$work/origin"
	mkdir -p "$origin"
	git -C "$origin" init -q
	git -C "$origin" config user.email ctest@example.com
	git -C "$origin" config user.name ctest
	echo "hello" >"$origin/README.md"
	git -C "$origin" add README.md
	git -C "$origin" -c commit.gpgsign=false commit -qm init
	git -C "$origin" tag v1

	chmod +x scripts/container/run-init.sh 2>/dev/null || true
	for img in $glibc_targets; do
		echo ">> $img"
		"$engine" run --rm \
			-v "$stage/ai-agent-init:/usr/local/bin/ai-agent-init:ro" \
			-v "$origin:/origin:ro" \
			-v "$PWD/scripts/container/run-init.sh:/run-init.sh:ro" \
			"$img" /run-init.sh || { echo "<<< $img FAILED >>>"; fail=1; }
	done
fi

for img in $musl_targets; do
	echo ">> $img (native musl build)"
	"$engine" run --rm -v "$PWD:/src" -w /src "$img" sh -euc '
		apk add --no-cache ldc dub gcc musl-dev zlib-dev git >/dev/null
		DFLAGS="-link-defaultlib-shared=false -L-lz" dub build :initializer --compiler=ldc2
		install -m755 packages/initializer/ai-agent-init /usr/local/bin/ai-agent-init
		git config --global user.email ctest@example.com
		git config --global user.name ctest
		mkdir -p /origin && cd /origin && git init -q && echo hello > README.md \
			&& git add README.md && git -c commit.gpgsign=false commit -qm init && git tag v1
		apk del git >/dev/null
		cd /src && sh scripts/container/run-init.sh
	' || { echo "<<< $img FAILED >>>"; fail=1; }
done

[ "$fail" -eq 0 ] && echo "ALL DISTROS PASSED" || echo "SOME DISTROS FAILED"
exit "$fail"
