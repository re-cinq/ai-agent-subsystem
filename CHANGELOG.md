# Changelog

All notable changes to this project are documented here. Image releases also carry
auto-generated GitHub release notes; this file records the human-facing summary and
the npm package versions.

## Unreleased

### Changed
- Migrated all JSON handling from `std.json` to `vibe.data.json`; CRD parsing is now a
  single lenient policy (`CrdPolicy` + `@optional`/`@wire`) so it cannot drift (#97).
- Agent-CLI installation is abstracted behind `AgentSetup` (claude / codex / opencode) (#96).

### Fixed
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
