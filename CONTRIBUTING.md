# Contributing

This is a [dub](https://dub.pm) monorepo: every D package lives under `packages/`, the docs site
under `website/`. This file is the map; the
[building guide](https://re-cinq.github.io/ai-agent-subsystem/contribute/building/) on the docs
site is the terrain — static-linking rationale, per-script details, and the cluster setup live
there.

## Toolchain

| Tool | Version | Needed for |
| --- | --- | --- |
| D compiler | DMD 2.111 (dev loop, CI) or LDC 1.40 (what ships; frontend 2.110) | everything under `packages/` |
| dub | 1.40+ (bundled with the compiler) | builds and tests |
| GNU make | any | the targets below |
| Node.js | 22 (`.nvmrc` in `website/` and `packages/agent-contracts/`) | contracts package, docs site |
| Docker + Buildx | recent | container tests, images |
| kubectl + kind or minikube | recent | controller integration tests only |
| python3 | 3.x | `scripts/pin-image-digests.sh` (release tooling) only |

`dub.json` declares `toolchainRequirements` (frontend >= 2.094 — the oldest CI-proven compiler,
debian:bullseye's LDC 1.24), so an unsupported compiler fails fast with a clear message instead of
a page of template errors.

LDC builds that ship (the image Dockerfiles, the portable `ai-agent-init` build) link with lld
(`--linker=lld`, so the builder needs the `lld` package). ld.bfd older than binutils 2.36, such as
Rocky 9's and debian:bullseye's 2.35, can split `.tbss` so that two thread-locals share storage;
`scripts/check-tbss.sh <binary>...` fails the build when that happens.

## Everyday commands

`make` (or `make help`) lists every target. The ones you will actually use:

```sh
make test    # unit tests for all six packages that have them
make build   # all runtime + codegen binaries
make itest   # host-level integration tests - no cluster, no docker, runs in seconds
make drift   # fail if generated CRDs / TS contracts drifted from the D model
make regen   # regenerate deploy/crds and packages/agent-contracts/src/types.generated.ts
make hooks   # install the pre-push hook that runs the drift checks
```

> Bare `dub test` at the repo root is a silent no-op (the root package is `targetType: none` and
> exits 0 without running anything). Always go through `make test` or name a package:
> `dub test :agentcore`.

A green `make test build drift itest` locally reproduces the main CI job — CI runs these same
targets with the same pinned compiler.

## Generated code

`deploy/crds/` and `packages/agent-contracts/src/types.generated.ts` are both generated from the
annotated structs in `packages/agentcore/source/agentcore/crds/`. If you touch those structs, run
`make regen` and commit the output; `make drift` (and CI) fails otherwise. `make hooks` installs a
pre-push hook so you find out before CI does. Skip it once with `git push --no-verify`.

Editing the structs usually also affects the TypeScript package's tests: `make contracts` runs its
vitest suite, which enforces 100% coverage — the same gate CI applies.

## Integration-test tiers

| Tier | Command | Needs |
| --- | --- | --- |
| Host | `make itest` | nothing beyond the D toolchain |
| Cross-distro containers | `make ctest` (or the individual `scripts/ctest-*.sh`) | docker |
| Controller on a cluster | `make itest-controller` | kind or minikube, kubectl, docker |
| Live batch event parity | `make itest-batch` (`VENDOR=gemini` for Gemini, `VENDOR=openai` for OpenAI/codex) | `ANTHROPIC_API_KEY` (or `GEMINI_API_KEY`, `OPENAI_API_KEY`), curl (spends two small calls); Gemini also needs node |

The ctest scripts take env overrides (`TARGETS`, `BUILDER_IMAGE`, `CONTAINER_ENGINE=podman`, ...);
each script's header documents its knobs. CI's container workflows call these same scripts, so a
local pass means CI parity.

### Recorded batch fixtures

The batch translator tests in `packages/agentcore` compare a batch run's events with a recorded
CLI run of the same vendor:

- Claude: `testdata/events/claude-cli.jsonl` (from `scripts/record-cli-events.sh`, which runs the
  CLI version pinned in `scripts/container/Dockerfile.agent` with the run pod's flags) and
  `testdata/batch/anthropic-batch-ended.json` plus `anthropic-result-succeeded.json` (from
  `scripts/record-batch-response.sh`, which submits a one-request batch, polls it every 30s until it
  ends, and deletes it). Both need `ANTHROPIC_API_KEY` and fail fast without it.
- Gemini: `testdata/events/gemini-cli.jsonl` (from `scripts/record-cli-events.sh "" gemini`, which
  runs the gemini-cli version pinned as `geminiCliVersion` in `vendors/gemini/setup.d`, or
  `GEMINI_CLI`, with the run pod's flags) and `testdata/batch/gemini-batch-succeeded.json` (from
  `scripts/record-batch-response.sh "" gemini`). Both need `GEMINI_API_KEY`.
  `testdata/events/gemini-cli-error.jsonl` is a real gemini-cli 0.62.0 run with an invalid key.
- Codex/OpenAI: `testdata/events/codex-cli.jsonl` (from `scripts/record-cli-events.sh "" codex`,
  which installs the codex CLI with the same unpinned installer `vendors/codex/setup.d` runs, or
  uses `CODEX_CLI`, with the run pod's flags) and `testdata/batch/openai-batch-completed.json` plus
  `openai-output-succeeded.json` (from `scripts/record-batch-response.sh "" openai`). Both need
  `OPENAI_API_KEY`; the CLI recorder hands it to codex as `CODEX_API_KEY`, the variable
  `codex exec` reads. `testdata/events/codex-cli-error.jsonl` is a real codex-cli 0.142.5 run with
  an invalid key.

**Pending re-record:** `gemini-cli.jsonl` and every `testdata/batch/gemini-*.json` fixture were
written by hand from gemini-cli 0.62.0's stream-json source and Google's Batch API reference,
because no `GEMINI_API_KEY` was available when Gemini batch support landed. Run
`make record-fixtures-gemini` (or `VENDOR=gemini KEEP_FIXTURES=1 make itest-batch`) with a key,
review the diff, commit it, and drop this note. `gemini-batch-pending.json`,
`gemini-batch-failed.json` and `gemini-batch-request-errored.json` have no recorder; reconcile them
with the recorded shapes by hand.

**Pending re-record:** `codex-cli.jsonl` and every `testdata/batch/openai-*.json` fixture were
written by hand from codex's `exec --json` event types (`codex-rs/exec/src/exec_events.rs`) and
OpenAI's Batch and Responses API docs, because no `OPENAI_API_KEY` was available when OpenAI batch
support landed. Run `make record-fixtures-openai` (or `VENDOR=openai KEEP_FIXTURES=1 make itest-batch`)
with a key, review the diff, commit it, and drop this note. `openai-request.json`,
`openai-batch-in-progress.json`, `openai-batch-failed.json` and `openai-output-errored.json` have no
recorder; reconcile them with the recorded shapes by hand.

- `make record-fixtures` re-records the Claude files in place, `make record-fixtures-gemini` the
  Gemini ones, `make record-fixtures-openai` the codex and OpenAI ones. Review the diff and commit it, for example after raising a CLI pin.
- `make itest-batch` records into a temp dir, puts the recordings over the fixtures, runs
  `dub test :agentcore`, then restores the committed fixtures. `VENDOR=gemini` does the same for
  Gemini, `VENDOR=openai` for codex and OpenAI. Set `KEEP_FIXTURES=1` to keep the recordings instead. Run it on release and whenever a CLI
  pin changes, to catch upstream event format changes. Unit tests never read live files: they only
  see what is in `testdata/`.

## Pull requests

- Conventional-commit style titles (`fix(output): ...`, `docs(changelog): ...`), squash-merged.
- Add a CHANGELOG.md entry under `Unreleased` for anything user-visible.
- CI must be green before merge.
