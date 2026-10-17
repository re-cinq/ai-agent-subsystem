#!/usr/bin/env bash
# Pull request delivery integration test: drives the real binaries through one
# delivering run against a local bare origin (file://) and a fake GitHub API (the
# mock agent's `serve` mode). The init clones with the token and must leave no push
# auth in the clone; the supervisor runs an agent that commits and bundles the work
# into the outbox; the courier pushes the branch, opens the pull request, and raises
# the delivery event. Also: a failed agent delivers nothing, and a courier whose
# outbox never fills fails at its deadline instead of hanging.
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

dub build :initializer >/dev/null
dub build :supervisor >/dev/null
dub build :mockagent >/dev/null

init="$repo/packages/initializer/ai-agent-init"
supervisor="$repo/packages/supervisor/ai-agent-supervisor"
mock="$repo/packages/mockagent/ai-agent-mock"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
check() { # check <name> <condition-rc>
	if [ "$2" -eq 0 ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; failures=$((failures + 1)); fi
}

# An origin with one commit on main, the base the pull request targets.
origin="$work/origin.git"
git init -q --bare --initial-branch=main "$origin"
seed="$work/seed"
git init -q --initial-branch=main "$seed"
echo "hello" >"$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" -c user.email=itest@example.com -c user.name=itest -c commit.gpgsign=false commit -qm init
git -C "$seed" push -q "$origin" HEAD:refs/heads/main

secret="s3cr3t-push-token-abc123"
port=18231
api_log="$work/api.log"
: >"$api_log"
MOCK_MODE=serve MOCK_SERVE_PORT=$port MOCK_SERVE_STATUS=201 MOCK_SERVE_LOG="$api_log" \
	MOCK_SERVE_BODY='{"number":7,"html_url":"https://github.example/o/app/pull/7"}' \
	"$mock" >"$work/serve.out" 2>/dev/null &
serve_pid=$!
trap 'kill "$serve_pid" 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 50); do grep -q listening "$work/serve.out" 2>/dev/null && break; sleep 0.1; done

plan() { # plan <workspace> <outbox> <branch>
	printf '{"repo":{"name":"app","url":"file://%s","token_secret":"GH_TOKEN_APP"},"slug":"o/app",' "$origin"
	printf '"branch":"%s","base":"main","title":"Fix ENG-1","draft":true,' "$3"
	printf '"apiUrl":"http://127.0.0.1:%s","clone":"%s/app","outbox":"%s"}' "$port" "$1" "$2"
}

clone() { # clone <workspace> <plan>
	GH_TOKEN_APP="$secret" AGENT_MODEL=gpt-5-codex WORKSPACE_DIR="$1" \
		AGENT_NAME=itest-agent POD_NAME=itest-pod AGENT_DELIVERY="$2" \
		AGENT_REPOS="[{\"name\":\"app\",\"url\":\"file://$origin\",\"token_secret\":\"GH_TOKEN_APP\"}]" \
		"$init" >/dev/null 2>&1
}

supervise() { # supervise <plan> <agent script>
	AGENT_NAME=itest-agent POD_NAME=itest-pod AGENT_DELIVERY="$1" \
		"$supervisor" -- sh -c "$2" >/dev/null 2>&1
}

courier() { # courier <home> <plan> <sink> [extra env...] -> sets rc, stdout in <home>/out
	mkdir -p "$1"
	env HOME="$1" GH_TOKEN_APP="$secret" AGENT_NAME=itest-agent POD_NAME=itest-pod \
		AGENT_SINKS="[{\"type\":\"file\",\"path\":\"$3\"}]" AGENT_DELIVERY="$2" "${@:4}" \
		"$init" courier >"$1/out" 2>"$1/err"
	rc=$?
}

commit_work='git -c user.email=agent@example.com -c user.name=agent -c commit.gpgsign=false'

# 1. A successful run that commits is pushed and opened as a pull request.
ws="$work/ws"
outbox="$work/outbox"
delivery="$(plan "$ws" "$outbox" agent/itest)"
clone "$ws" "$delivery"
check "init clones the repo" "$([ -f "$ws/app/README.md" ] && echo 0 || echo 1)"
check "clone keeps no credential helper" "$(! git -C "$ws/app" config --get credential.helper >/dev/null && echo 0 || echo 1)"
check "clone keeps no token file or auth header" \
	"$([ ! -e "$ws/app/.git/agent-token" ] && [ ! -e "$ws/app/.git/agent-auth.gitconfig" ] && echo 0 || echo 1)"
check "the token is nowhere in the clone" "$(! grep -rqF "$secret" "$ws" && echo 0 || echo 1)"

supervise "$delivery" "cd $ws/app && echo fix >fix.txt && git add fix.txt && $commit_work commit -qm 'fix ENG-1'"
check "supervisor leaves a ready outcome" "$(grep -q '"state":"ready"' "$outbox/outcome.json" && echo 0 || echo 1)"
check "supervisor leaves the bundle" "$([ -s "$outbox/run.bundle" ] && echo 0 || echo 1)"

sink="$work/sink.jsonl"
: >"$sink"
courier "$work/courier" "$delivery" "$sink"
check "courier exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "branch pushed with the agent's commit" \
	"$([ "$(git -C "$origin" log -1 --format=%s agent/itest 2>/dev/null)" = "fix ENG-1" ] && echo 0 || echo 1)"
check "pull request posted to the repo's pulls" "$(grep -q 'POST /repos/o/app/pulls' "$api_log" && echo 0 || echo 1)"
check "API call authenticated with the token" "$(grep -qF "Authorization: Bearer $secret" "$api_log" && echo 0 || echo 1)"
check "pull request body names title, head, base and draft" \
	"$(grep -F '"title":"Fix ENG-1"' "$api_log" | grep -F '"head":"agent/itest"' | grep -F '"base":"main"' | grep -qF '"draft":true' && echo 0 || echo 1)"
check "delivery event carries the pull request url" \
	"$(grep -F '"kind":"delivery"' "$work/courier/out" | grep -F '"status":"opened"' | grep -qF 'https://github.example/o/app/pull/7' && echo 0 || echo 1)"
check "delivery event reaches the sink" "$(grep -qF '"kind":"delivery"' "$sink" && echo 0 || echo 1)"
check "token never reaches the courier log or the sink" \
	"$(! grep -qF "$secret" "$work/courier/out" "$work/courier/err" "$sink" && echo 0 || echo 1)"

# 2. A failed agent leaves an empty outcome; the courier skips and pushes nothing.
ws2="$work/ws2"
outbox2="$work/outbox2"
delivery2="$(plan "$ws2" "$outbox2" agent/failed)"
clone "$ws2" "$delivery2"
supervise "$delivery2" "cd $ws2/app && $commit_work commit -q --allow-empty -m half && exit 3"
check "failed agent leaves an empty outcome" "$(grep -q '"state":"empty"' "$outbox2/outcome.json" && echo 0 || echo 1)"
courier "$work/courier2" "$delivery2" "$work/sink2.jsonl"
check "courier skips with exit 0" "$([ "$rc" -eq 0 ] && grep -q '"status":"skipped"' "$work/courier2/out" && echo 0 || echo 1)"
check "nothing pushed for a failed agent" "$(! git -C "$origin" rev-parse -q --verify refs/heads/agent/failed >/dev/null && echo 0 || echo 1)"

# 3. An outbox that never fills fails the courier at its deadline instead of hanging.
delivery3="$(plan "$work/ws3" "$work/outbox3" agent/never)"
courier "$work/courier3" "$delivery3" "$work/sink3.jsonl" AGENT_DEADLINE_MS=1
check "courier with no outcome exits 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
check "courier reports the missing outcome" \
	"$(grep -q '"status":"failed"' "$work/courier3/out" && grep -q 'no outbox outcome' "$work/courier3/out" && echo 0 || echo 1)"

if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; else echo "$failures CHECK(S) FAILED"; fi
[ "$failures" -eq 0 ]
