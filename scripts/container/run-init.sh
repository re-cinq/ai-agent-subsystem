#!/bin/sh
# Runs INSIDE a minimal container where git/curl are absent, proving ai-agent-init
# self-bootstraps its prerequisites through the distro package manager and then
# provisions for real. Test A (git clone) always runs; Test B (the real Claude
# install) is opt-in via CTEST_CLAUDE=1 and skips itself when claude.ai is
# unreachable. POSIX sh (no bashisms) so it runs on Alpine's busybox shell too.
#
# Test A's gpt-5-codex model routes to the Codex CLI installer; this script stages
# a stub `codex` on PATH (below), so its `command -v` guard skips the real network
# install and Test A stays focused on the git self-bootstrap path. The real vendor
# installers are the opt-in, network Test B concern.
set -u
fail=0
chk() { if [ "$2" -eq 0 ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }

# We clone from a host-mounted repo owned by a different uid than this container,
# so git's dubious-ownership guard would block the clone. git only honours
# safe.directory from its system/global config (not from env or -c), so write it
# to the system config now — it's just a file, no git needed yet. (Real runs clone
# from a remote url, so this is purely a bind-mount test concession.)
printf '[safe]\n\tdirectory = *\n' > /etc/gitconfig 2>/dev/null || true

# Stage a stub `codex` on PATH so Test A's gpt-5-codex run skips the real Codex CLI
# install (its `command -v codex` guard finds this) and stays an offline git test.
# Done here, not in a Dockerfile, because the CI workflow bind-mounts this script
# into a bare distro image and runs it directly. Real installers are the Test B path.
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/codex 2>/dev/null && chmod +x /usr/local/bin/codex 2>/dev/null || true

# shellcheck disable=SC1091
echo "distro: $( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}" )"

# --- Test A: git self-bootstrap + real clone --------------------------------
if command -v git >/dev/null 2>&1; then
	echo "  SKIP  git self-bootstrap (git already present in base image)"
else
	sink=/tmp/sink-git.jsonl
	: >"$sink"
	# HOME must be set and writable: every run now provisions an agent CLI, and the
	# installers write under $HOME (the guarded codex step no-ops here, but the
	# precondition still applies).
	HOME=/tmp AGENT_MODEL=gpt-5-codex \
		WORKSPACE_DIR=/workspace \
		AGENT_SINKS="[{\"type\":\"file\",\"path\":\"$sink\"}]" \
		AGENT_NAME=ctest POD_NAME=ctest-pod \
		AGENT_REPOS='[{"name":"app","url":"file:///origin","ref":"v1"}]' \
		ai-agent-init
	rc=$?
	chk "init exits 0 after self-bootstrap" "$([ $rc -eq 0 ] && echo 0 || echo 1)"
	chk "git was installed by the init" "$(command -v git >/dev/null 2>&1 && echo 0 || echo 1)"
	chk "repo cloned into workspace" "$([ -f /workspace/app/README.md ] && echo 0 || echo 1)"
	chk "checked out the pinned tag" "$( [ "$(git -C /workspace/app describe --tags --exact-match HEAD 2>/dev/null)" = "v1" ] && echo 0 || echo 1 )"
	chk "succeeded event on the sink" "$(grep -q '"status":"succeeded"' "$sink" && echo 0 || echo 1)"

	# Argv injection defense (issue #99) across this distro's git version: an
	# option-shaped ref must be rejected as data, never switch HEAD to it. git's
	# arg parsing varies by version, so this guards the fix on every base image.
	HOME=/tmp AGENT_MODEL=gpt-5-codex \
		WORKSPACE_DIR=/workspace-inject \
		AGENT_NAME=ctest POD_NAME=ctest-pod \
		AGENT_REPOS='[{"name":"app","url":"file:///origin","ref":"--orphan=pwned"}]' \
		ai-agent-init >/dev/null 2>&1
	chk "option-shaped ref fails the init" "$([ $? -ne 0 ] && echo 0 || echo 1)"
	chk "option-shaped ref never switched HEAD to the injected branch" \
		"$([ "$(git -C /workspace-inject/app symbolic-ref --short HEAD 2>/dev/null)" != "pwned" ] && echo 0 || echo 1)"
fi

# --- Test B (opt-in): real Claude CLI install -------------------------------
if [ "${CTEST_CLAUDE:-0}" = "1" ]; then
	# curl is needed even to probe reachability; install it if the base lacks it.
	if ! command -v curl >/dev/null 2>&1; then
		{ command -v apt-get >/dev/null 2>&1 && apt-get update && apt-get install -y --no-install-recommends curl ca-certificates; } >/dev/null 2>&1 || true
		{ command -v dnf >/dev/null 2>&1 && dnf install -y curl; } >/dev/null 2>&1 || true
		{ command -v apk >/dev/null 2>&1 && apk add --no-cache curl ca-certificates; } >/dev/null 2>&1 || true
	fi
	if curl -fsSI https://downloads.claude.ai/ >/dev/null 2>&1; then
		export HOME=/root
		AGENT_MODEL=claude-sonnet-4-6 WORKSPACE_DIR=/workspace ai-agent-init
		rc=$?
		chk "claude install exits 0" "$([ $rc -eq 0 ] && echo 0 || echo 1)"
		chk "claude binary installed to ~/.local/bin" "$([ -x "$HOME/.local/bin/claude" ] && echo 0 || echo 1)"
	else
		echo "  SKIP  claude install (downloads.claude.ai unreachable)"
	fi
fi

if [ "$fail" -eq 0 ]; then echo "CONTAINER TESTS PASSED"; else echo "CONTAINER TESTS FAILED"; fi
exit "$fail"
