#!/bin/sh
# Runs INSIDE a target glibc distro to prove the supervisor — built once on Rocky 9
# (the oldest glibc + openssl 3 among the glibc Kubernetes distros) — works there.
# The supervisor links vibe-d, so it needs libssl.so.3; this installs it if the
# minimal base lacks it. The ldc runtime shared libs are staged alongside the
# binaries and found via LD_LIBRARY_PATH. Runs the real integration suite against
# the supervisor + mock agent. POSIX sh.
set -u
stage="${STAGE_DIR:-/opt/sup}"

# shellcheck disable=SC1091
echo "distro: $( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}" )"

# The supervisor needs libssl.so.3 (vibe-d); install it if the base image lacks it.
if ! ldconfig -p 2>/dev/null | grep -q 'libssl\.so\.3'; then
	{ command -v apt-get >/dev/null 2>&1 && apt-get update >/dev/null 2>&1 && apt-get install -y openssl >/dev/null 2>&1; } \
		|| { command -v dnf >/dev/null 2>&1 && dnf install -y openssl-libs >/dev/null 2>&1; } \
		|| { command -v microdnf >/dev/null 2>&1 && microdnf install -y openssl-libs >/dev/null 2>&1; } \
		|| true
fi

export LD_LIBRARY_PATH="$stage${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$stage/ai-agent-itest" "$stage/ai-agent-supervisor" "$stage/ai-agent-mock" || exit 1

# A pod on a runtime with an unlimited open-file limit (containerd 2.x: soft = hard =
# 2147483584) starts the supervisor with that limit, and an LDC build's std.process sizes
# a per-descriptor buffer from it in every forked child, so the memory cap kills the first
# spawn. The supervisor must lower its own limit before spawning its agent.
out="$( (ulimit -S -n "$(ulimit -H -n)" && exec env AGENT_NAME=a STATION_NAME=s POD_NAME=p POD_NAMESPACE=ns MOCK_LINES=2 \
	"$stage/ai-agent-supervisor" -- "$stage/ai-agent-mock") 2>&1 )"
rc=$?
echo "  supervisor under an unlimited open-file limit: exit $rc"
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"status":"succeeded"'; then
	echo "  PASS  supervisor spawns its agent under an unlimited open-file limit"
else
	echo "  FAIL  supervisor spawns its agent under an unlimited open-file limit"
	printf '%s\n' "$out"
	exit 1
fi
