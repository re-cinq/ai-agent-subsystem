# Changelog

All notable changes to this project are documented here. Image releases also carry
auto-generated GitHub release notes; this file records the human-facing summary and
the npm package versions.

## Unreleased

### Added
- A contributor on-ramp: root `CONTRIBUTING.md` (toolchain table, everyday commands,
  integration-test tiers) and a root `Makefile` as the single dev entry point —
  `make help` lists targets, and CI's main job now runs the same
  `make test / build / drift / itest` it documents. `make hooks` installs a pre-push
  hook running the generated-code drift checks locally (#175).
- `scripts/ctest-init-portable.sh` extracts the init-container cross-distro test out
  of CI-only workflow YAML so it runs locally too; the supervisor container workflow
  now calls `ctest-supervisor.sh` (new `STAGE_DIR`/`BUILD_ONLY`/`SKIP_BUILD` knobs)
  instead of carrying an inline copy that had already drifted (#175).

### Changed
- The toolchain is pinned: CI builds with `dmd-2.111.0` instead of a floating
  `dmd-latest`, `dub.json` declares a compiler floor (frontend >= 2.094, bullseye's
  LDC 1.24), and Node standardizes on 22 across CI with `.nvmrc` files (#175).

### Fixed
- The README's documentation links pointed at the retired
  `glowing-garbanzo-y7ek98q.pages.github.io` hostname and omitted the site base, so
  every link 404'd; they now target https://re-cinq.github.io/ai-agent-subsystem/ (#175).

## v0.6.2

### Fixed
- stdout (pod logs, and the `Agent.status.output` capped from them) now carries the
  bare event line; the `{"source", "event"}` attribution envelope is applied only at
  sink delivery, where streams from many pods merge. Wrapping stdout leaked the
  envelope into `status.output`, whose downstream parsers expect the tool's own
  claude-style result line — a review could record its verdict while its findings
  never parsed. `wrapEvent` now enforce-throws when asked to wrap an already-wrapped
  line, so the envelope can never nest (#171).
- The supervisor itest asserts the new contract — stdout events carry no source ids
  and no envelope; the file/http sink checks keep covering ids-on-sinks (#172).

## v0.6.1

### Fixed
- Run pods now carry `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, so a
  cluster-autoscaler node scale-down no longer evicts a live run mid-flight — with
  `backoffLimit: 0` a single eviction failed the whole attempt with
  `BackoffLimitExceeded` and no output. Station-supplied pod annotations are
  preserved (the run's stamp wins on its key) (#168).

## v0.6.0

### Fixed
- The run pod now shares a `workspace` volume between the init and agent containers —
  previously the clone landed in the init container's own filesystem layer and vanished
  when init exited, so the agent found no repo (#164).
- The init container hands `$HOME` and the workspace to the agent uid/gid after
  provisioning. fsGroup only chowns volume roots at mount; everything init (root) created
  was root-owned 0755, so the agent could neither write its HOME (Claude Code fails on
  `mkdir $HOME/.claude/session-env`) nor edit the cloned repo (#164).
- The first repo credential is also injected as `GH_TOKEN` — the per-task key carries a
  run-scoped name, so `gh` ran unauthenticated and 404'd on private repos (#164).

## v0.5.1

Re-release of v0.5.0 with **no code changes**. The v0.5.0 tag could not carry a GitHub
Release (an immutable-release tag collision), so the digest-pinned images and
`install.yaml` ship under v0.5.1 instead. Pin consumers to the v0.5.1 digests.

## v0.5.0

### Changed
- Migrated all JSON handling from `std.json` to `vibe.data.json`; CRD parsing is now a
  single lenient policy (`CrdPolicy` + `@optional`/`@wire`) so it cannot drift (#97).
- Agent-CLI installation is abstracted behind `AgentSetup` (claude / codex / opencode) (#96).

### Fixed
- A repo's `token_secret` is now injected as a `secretKeyRef` env of the same name, so the
  init container's `git clone` authenticates. It was serialised into `AGENT_REPOS` as
  metadata but never materialised as an env var, so every clone ran with an empty token and
  failed `remote: Invalid username or token` — stalling the assembly-line walk (#160).
- The controller surfaces non-200 watch responses instead of spinning in a silent dead
  loop (#94), and the inform, poll and election loops now contain library-level `Error`s
  so one bad interaction can't crash the HA controller (#92).
- History pruning is scoped per Station rather than across the whole namespace (#91), and
  CRD spec parsing is generated from the structs so it cannot drift from the schema (#90).

## v0.3.0

### Added
- **`@re-cinq/agent-contracts`** — a published TypeScript package with the
  `Agent` / `Station` / `AgentDefinition` types **generated from the D CRD structs**
  (`packages/tsgen`, the same `agentcore.crds` model `crdgen` reads) plus a thin,
  transport-injected client (`createAgent` / `getAgent` / `findAgents` /
  `applyAgentDefinition` / `applyStation` / `waitForAgent`). The CRDs remain the
  source of truth; the generated types cannot drift (CI runs
  `scripts/check-contracts-drift.sh`).

### Notes
- The controller + agent images are republished at `v0.3.0` (digest-pinned, signed).
- Consumers (e.g. Lore's Floor and web UI) import `@re-cinq/agent-contracts@0.3.0`
  instead of re-declaring the resource shapes.

## v0.2.0
- Released container images (controller + agent), signed with cosign + SBOM/SLSA.

## v0.1.0
- Initial release of the ai-agent-subsystem operator.
