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
exec "$stage/ai-agent-itest" "$stage/ai-agent-supervisor" "$stage/ai-agent-mock"
