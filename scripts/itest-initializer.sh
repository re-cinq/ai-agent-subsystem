#!/usr/bin/env bash
# Initializer integration tests: build ai-agent-init, then drive the real binary
# against a throwaway local git repo and assert on its observable behaviour —
# clone, idempotent retry, lifecycle notifications to a file sink, and a clean
# non-zero on a bad repo. The Claude installer and package-manager installs are
# not exercised here (network/root); their argv is covered by agentcore unittests.
# AGENT_MODEL is a codex model so the Claude tool stays inactive.
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
	AGENT_MODEL=gpt-5-codex \
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
	AGENT_MODEL=gpt-5-codex \
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

# 4. Argv injection defense (issue #99). An operator-authored recipe whose `ref`
# or `url` begins with `-` must reach git as data, never as a flag. The init runs
# real git, so these drive the actual clone/checkout the init container would.
runerr() { # runerr <workspace> <repos-json> -> sets rc and $err (init stderr)
	err="$1/stderr.log"
	AGENT_MODEL=gpt-5-codex \
		WORKSPACE_DIR="$1" \
		AGENT_NAME=itest-agent POD_NAME=itest-pod \
		AGENT_REPOS="$2" \
		"$init" >/dev/null 2>"$err"
	rc=$?
}

# Without the `--` separator, `ref: "--orphan=pwned"` makes `git checkout` switch
# to a new orphan branch and exit 0 — arbitrary git-option execution as root. With
# the fix, git treats it as a pathspec, the step fails, and HEAD never moves.
ws_ref="$work/ws-ref"
mkdir -p "$ws_ref"
runerr "$ws_ref" "[{\"name\":\"app\",\"url\":\"file://$origin\",\"ref\":\"--orphan=pwned\"}]"
check "option-shaped ref fails the init" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "option-shaped ref never switched HEAD to the injected branch" \
	"$([ "$(git -C "$ws_ref/app" symbolic-ref --short HEAD 2>/dev/null)" != "pwned" ] && echo 0 || echo 1)"

# An option-shaped `url` (e.g. an `--upload-pack=<cmd>` payload) must be parsed as
# a repository name, so the injected command never runs. git reports the whole
# string as the missing repository — proof it was a positional, not a flag.
ws_url="$work/ws-url"
mkdir -p "$ws_url"
sentinel="$work/pwned-by-upload-pack"
runerr "$ws_url" "[{\"name\":\"app\",\"url\":\"--upload-pack=touch $sentinel foo@bar\"}]"
check "option-shaped url fails the init" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "option-shaped url never executed the injected command" "$([ ! -e "$sentinel" ] && echo 0 || echo 1)"
check "option-shaped url treated as a repository name, not a flag" \
	"$(grep -qF "repository '--upload-pack=touch $sentinel foo@bar'" "$err" && echo 0 || echo 1)"

# 5. Path-traversal guard (issue #100). The init emits `rm -rf <dest>` before each
# clone; a recipe `path` that escapes the workspace — via `..` or an absolute system
# path — must never reach that rm. Plant a canary *outside* the workspace, point a
# repo at it, run the real binary, and assert the canary survives and nothing was
# cloned onto it. The unsafe repo is skipped, so init still exits 0.
canary="$work/canary"
mkdir -p "$canary"
echo "precious" >"$canary/keep.txt"

# 5a. Relative escape: path "../canary" resolves to $work/canary, outside the ws.
: >"$sink"
run "$work/ws-trav" "$sink" "[{\"name\":\"app\",\"url\":\"file://$origin\",\"path\":\"../canary\"}]"
check "relative-traversal recipe exits 0 (skipped, not fatal)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "canary survives a '../' escape path" "$([ -f "$canary/keep.txt" ] && echo 0 || echo 1)"
check "'../' escape path never cloned onto the canary" "$([ ! -e "$canary/.git" ] && echo 0 || echo 1)"

# 5b. Absolute escape: an absolute path outside the workspace is rejected too.
: >"$sink"
run "$work/ws-abs" "$sink" "[{\"name\":\"app\",\"url\":\"file://$origin\",\"path\":\"$canary\"}]"
check "absolute-escape recipe exits 0 (skipped, not fatal)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "canary survives an absolute out-of-workspace path" "$([ -f "$canary/keep.txt" ] && echo 0 || echo 1)"

# 5c. The guard blocks only escapes: a legit path *under* the workspace still clones.
: >"$sink"
run "$work/ws-nest" "$sink" "[{\"name\":\"app\",\"url\":\"file://$origin\",\"path\":\"nested/app\"}]"
check "nested in-workspace path still clones" "$([ -f "$work/ws-nest/nested/app/README.md" ] && echo 0 || echo 1)"

if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; else echo "$failures CHECK(S) FAILED"; fi
[ "$failures" -eq 0 ]
