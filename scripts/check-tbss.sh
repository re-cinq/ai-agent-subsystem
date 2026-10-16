#!/bin/sh
# Fail if any given ELF binary has more than one .tbss section.
#
#   scripts/check-tbss.sh packages/controller/ai-agent-controller [more binaries...]
#
# A linker that predates SHF_GNU_RETAIN (ld.bfd < 2.36, e.g. Rocky 9's and Debian
# bullseye's binutils 2.35) emits a retained input .tbss as a SECOND .tbss output
# section at the same address as the first, so two thread-locals share storage.
# LDC's integrated assembler marks some .tbss retained, so every LDC build links
# with lld, and this check keeps an old ld.bfd from slipping back in. POSIX sh, so
# it runs in every builder image (Rocky, Debian, Alpine/busybox).
set -eu

[ "$#" -gt 0 ] || { echo "usage: $0 BINARY..." >&2; exit 2; }

for bin in "$@"; do
	sections="$(readelf -SW "$bin")"
	count="$(printf '%s\n' "$sections" | grep -c ' \.tbss ' || true)"
	[ "$count" -le 1 ] || { echo "$bin: $count .tbss sections, so thread-locals alias each other" >&2; exit 1; }
done
