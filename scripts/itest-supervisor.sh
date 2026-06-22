#!/usr/bin/env bash
# Supervisor integration tests: build the supervisor + mock agent + test runner,
# then run the suite against the real binaries.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

dub build :mockagent >/dev/null
dub build :supervisor >/dev/null
dub build :itest >/dev/null

timeout 120 ./packages/itest/ai-agent-itest \
	./packages/supervisor/ai-agent-supervisor \
	./packages/mockagent/ai-agent-mock
