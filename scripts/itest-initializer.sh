#!/usr/bin/env bash
# Initializer integration tests: build ai-agent-init, then drive the real binary
# against a throwaway local git repo and assert on its observable behaviour —
# clone, idempotent retry, lifecycle notifications to a file sink, and a clean
# non-zero on a bad repo. The Claude installer and package-manager installs are
# not exercised here (network/root); their argv is covered by agentcore unittests.
# LORE_MODEL is a codex model so the Claude tool stays inactive.
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

dub build :initializer >/dev/null

init="$repo/packages/initializer/ai-agent-init"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# An origin repo with one commit on a tag, served over file://.
origin="$work/origin"
mkdir -p "$origin"
git -C "$origin" init -q
git -C "$origin" config user.email itest@example.com
git -C "$origin" config user.name itest
echo "hello" >"$origin/README.md"
git -C "$origin" add README.md
git -C "$origin" -c commit.gpgsign=false commit -qm "init"
git -C "$origin" tag v1

failures=0
check() { # check <name> <condition-rc>
	if [ "$2" -eq 0 ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; failures=$((failures + 1)); fi
}

run() { # run <workspace> <sink-file> <repos-json>  -> sets rc
	LORE_MODEL=gpt-5-codex \
		WORKSPACE_DIR="$1" \
		AGENT_SINKS="[{\"type\":\"file\",\"path\":\"$2\"}]" \
		AGENT_NAME=itest-agent POD_NAME=itest-pod \
		AGENT_REPOS="$3" \
		"$init" >/dev/null
	rc=$?
}

# 1. Clone a declared repo, pinned to a tag, into the workspace.
ws="$work/ws"
sink="$work/sink.jsonl"
: >"$sink"
run "$ws" "$sink" "[{\"name\":\"app\",\"url\":\"file://$origin\",\"ref\":\"v1\"}]"
check "clone exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "repo cloned into workspace" "$([ -f "$ws/app/README.md" ] && echo 0 || echo 1)"
check "checked out the requested ref" "$([ "$(git -C "$ws/app" rev-parse HEAD)" = "$(git -C "$origin" rev-parse v1)" ] && echo 0 || echo 1)"
check "started event on the file sink" "$(grep -q '"status":"started"' "$sink" && echo 0 || echo 1)"
check "succeeded event on the file sink" "$(grep -q '"status":"succeeded"' "$sink" && echo 0 || echo 1)"
check "events carry the run id" "$(grep -q '"agent":"itest-agent"' "$sink" && echo 0 || echo 1)"

# 1b. Private-repo auth: the token is read from its env var via a git credential
# helper. file:// ignores the helper, so this checks the auth flags don't break a
# clone and — the security property — that the token value never leaks to a sink.
ws_auth="$work/ws-auth"
sink_auth="$work/sink-auth.jsonl"
: >"$sink_auth"
secret="s3cr3t-token-abc123"
GH_TOKEN="$secret" \
	LORE_MODEL=gpt-5-codex \
	WORKSPACE_DIR="$ws_auth" \
	AGENT_SINKS="[{\"type\":\"file\",\"path\":\"$sink_auth\"}]" \
	AGENT_NAME=itest-agent POD_NAME=itest-pod \
	AGENT_REPOS="[{\"name\":\"app\",\"url\":\"file://$origin\",\"token_secret\":\"GH_TOKEN\"}]" \
	"$init" >/dev/null
rc=$?
check "private-repo clone exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "private-repo cloned into workspace" "$([ -f "$ws_auth/app/README.md" ] && echo 0 || echo 1)"
check "token value never leaks to the sink" "$(! grep -q "$secret" "$sink_auth" && echo 0 || echo 1)"

# 2. Re-entrant: a second run over the same (non-empty) workspace still succeeds.
: >"$sink"
run "$ws" "$sink" "[{\"name\":\"app\",\"url\":\"file://$origin\",\"ref\":\"v1\"}]"
check "idempotent re-run exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "repo present after re-run" "$([ -f "$ws/app/README.md" ] && echo 0 || echo 1)"

# 3. A bad repo url fails the init and reports it.
: >"$sink"
run "$work/ws-bad" "$sink" "[{\"name\":\"nope\",\"url\":\"file://$work/does-not-exist\"}]"
check "bad repo exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "failed event on the file sink" "$(grep -q '"status":"failed"' "$sink" && echo 0 || echo 1)"

if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; else echo "$failures CHECK(S) FAILED"; fi
[ "$failures" -eq 0 ]
