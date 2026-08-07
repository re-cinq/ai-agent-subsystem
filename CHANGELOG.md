# Changelog

All notable changes to this project are documented here. Image releases also carry
auto-generated GitHub release notes; this file records the human-facing summary and
the npm package versions.

## Unreleased

### Fixed
- The supervisor now has its own run deadline, injected as `AGENT_DEADLINE_MS` a fixed
  margin inside the Job's `activeDeadlineSeconds`. An agent that neither exits nor emits
  a terminal event left the supervisor waiting until the kubelet killed the pod at the
  Job deadline — which took the terminal `agentExit` event with it, so a wedged run just
  stopped, with no terminal event for a consumer to act on. The supervisor now forces the
  agent down (SIGTERM, then SIGKILL) and still reports, exiting 124 (#48).
- The agent's stderr is captured and forwarded to the pod log tagged `[agent]`, instead
  of being inherited raw. It is where a CLI prints auth failures, rate limits and stack
  traces, and inherited it interleaved with the JSONL event stream the controller caps
  into `status.output`, where a consumer could not tell a crash trace from a malformed
  event (#47).
- The supervisor itest harness drains stdout and stderr concurrently. Reading stdout to
  EOF first deadlocks once the supervisor's stderr fills its 64 KiB pipe buffer — it
  blocks on that write, so stdout never reaches EOF and neither stream completes. Latent
  while the supervisor barely used stderr, and a hang the moment it began forwarding the
  agent's; part of (#127).
- `check-contracts-version.sh` fails a `v*` tag whose
  `packages/agent-contracts/package.json` version does not match it. The npm version is
  committed, not derived, so a release PR that forgot the bump republished an existing
  version — npm rejected it with an error that reads like an auth failure, and v0.5.0
  through v0.7.0 all shipped images while npm stayed on 0.3.0 (#139).

## v0.8.0

### Added
- A skills seam on the recipe: `resources.skills` (names) and `resources.skills_source`
  (a registry base URL). Stations ran headless `claude --print` with no skills and no
  hooks; now the init container's `SkillsTool` fetches `<source>/settings.json` (the
  org's session hooks) and `<source>/<name>.tar.gz` per named skill into the run's
  `$HOME/.claude`, plus the cloned repo's own `.claude/skills`. `HOME=/agent` is where
  headless claude auto-loads user scope trust-free — project scope under cwd `/` never
  fires. The Claude adapter emits `--settings /agent/.claude/settings.json` through a
  shared `kube.bundle` path so the flag cannot drift from the stager. The recipe
  declares intent and each adapter realizes it, so the seam stays agent-agnostic (#180).

### Changed
- Skills and settings are **fetched**, never baked. An earlier cut of #180 shipped a
  bundle inside the agent image; the subsystem must stay consumer-agnostic, so nothing
  org-specific lives in the image now. The registry URL is read from
  `$AGENT_SKILLS_SOURCE` at run time so a recipe URL never enters the shell command,
  and skill names are re-validated against injection before use (#180).

### Notes
- `@re-cinq/agent-contracts` is republished at **0.8.0**, carrying the generated
  `skills` / `skills_source` fields.

## v0.7.0

### Added
- `AgentDefinition.resources.mcp_servers` is actually wired into the run — it was
  modeled but never injected, so a pod never saw the MCP tools its recipe declared.
  The Claude adapter now renders the entries into an inline `--mcp-config` JSON plus
  `--strict-mcp-config` (the pod's cwd is `/`, so project-dir auto-load never fires),
  and `runEnv` injects each `headers_secret` as a `secretKeyRef` env from
  `agent-secrets`. An http/sse `Authorization` value is a `${ENV}` reference Claude
  expands at runtime, so the token never rides in argv; both sides derive the same
  shell-safe name through `headerEnvName` (`lore-mcp-auth` → `${LORE_MCP_AUTH}`)
  because `${}` expansion rejects the hyphens a secret key allows (#177).
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
- `disallowedTools` is emitted in every permission mode, not just the non-bypass ones.
  Bypass only skips the interactive prompts — it must never silently re-enable a tool
  the recipe explicitly denied, which matters now that a pod can hold live MCP tools
  (the seeded recipe denies `lore_create_pipeline_task` so a run cannot spawn more
  tasks) (#177).
- The README's documentation links pointed at the retired
  `glowing-garbanzo-y7ek98q.pages.github.io` hostname and omitted the site base, so
  every link 404'd; they now target https://re-cinq.github.io/ai-agent-subsystem/ (#175).

### Security
- Run pods: `enforceNoHostEscapes` rejects a Station pod template that smuggles a node
  escape through the preserve-unknown-fields passthrough — host namespaces, `hostPath`
  volumes, or a privileged container — before the spec reaches the kubelet. The init
  container drops ALL capabilities and adds back only
  CHOWN/DAC_OVERRIDE/FOWNER/SETUID/SETGID, with `allowPrivilegeEscalation: false` and
  runtime-default seccomp; it still runs as root to provision the workspace (#176).
- CI: least-privilege `permissions: contents: read` across the workflows, and
  `images.yml`'s publish job now requires the triggering CI run to belong to this
  repo's own `main`. A fork PR's `workflow_run` carries the fork's branch name, so
  without the `head_repository` guard a fork branch named `main` could have its commit
  built, pushed to GHCR, and cosign-signed with our OIDC identity (#176).
- Deploy: the namespace enforces Pod Security Admission `baseline` (warn/audit
  `restricted`), the controller image is pinned inline by digest so a bare
  `kubectl apply -f` is safe, and agent egress now excludes the CGNAT
  `100.64.0.0/10` range used by GKE/EKS. External model APIs, git forges and
  registries stay reachable — a legitimate run is unaffected (#176).

### Notes
- `@re-cinq/agent-contracts` is republished at **0.7.0**. The package version had been
  stuck at 0.3.0 while the generated types moved on, so every tag since published
  nothing; the version now tracks the release tag.

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
