# System Specification — ai-agent-subsystem

## Overview

The ai-agent-subsystem is a Kubernetes-native platform for running autonomous AI coding agents as
first-class cluster resources. Users describe the work to be done, select an agent runtime, and
launch a run — a reconciling controller handles lifecycle management. Kubernetes is the single source
of truth: a run *is* a CRD resource, and its result lives on that resource's `status` field.

The system is a statically linked D monorepo producing three runtime binaries plus a shared library.
It has no runtime dependencies beyond a Kubernetes cluster.

## Key Capabilities

- **Declarative agent execution**: Define agents, runtimes, and runs as YAML — no custom tooling
  needed beyond `kubectl`.
- **Controller-reconciled lifecycle**: A leader-elected controller watches `Agent` resources, creates
  Kubernetes Jobs for each run, supervises them, patches status on completion, and prunes old runs.
- **Injected agent toolchain**: The agent CLI (Claude Code or compatible) is injected at runtime via
  an init container — Stations only need a glibc-based base image.
- **Secure by default**: Non-root (UID 1000), read-only root filesystem, all capabilities dropped,
  NetworkPolicy-restricted, cosign-signed images with SLSA provenance and SPDX SBOMs.
- **Published TypeScript contracts**: The `@re-cinq/agent-contracts` npm package exposes typed
  Kubernetes client wrappers generated directly from the D source — types cannot drift.
- **One-command install**: A single `kubectl apply -f install.yaml` brings up the full subsystem
  (CRDs, RBAC, NetworkPolicy, controller) with digest-pinned images.

## Core Data Model

Three Custom Resources form a reference chain:

```
AgentDefinition  →  Station  →  Agent  →  Job → Pod
```

### AgentDefinition

The recipe. Declares: prompt template, model provider and parameters, allowed tools, tool
permissions (file paths, network, shell commands), and output sinks. Multiple Stations may reference
one AgentDefinition.

### Station

The runtime. Holds: a reference to an AgentDefinition, a Pod template (image, env, resource limits),
and run-history retention limits. Stations are reusable; multiple Agent runs share a Station.

### Agent

One run. Holds: a reference to a Station, per-run parameter overrides (prompt variables), and a
lifecycle `status` (phase, start/end time, output tail). The controller creates a Job per Agent and
patches status as the Job progresses. The output tail is bounded by `MAX_OUTPUT_BYTES` (default
256 KiB) to stay under etcd's per-object limit.

## Component Architecture

| Component | Role |
| --- | --- |
| `agentcore` | Shared library: CRD type definitions, Kubernetes HTTP client, reconcile state machine, prompt templating, Job builder |
| `controller` | Kubernetes operator; runs with 2 replicas (HA), leader-elected via Lease; reconciles Agents into Jobs |
| `initializer` | Init container for each run Pod; clones repos and installs the agent CLI before the agent process starts |
| `supervisor` | Sidecar/main process inside each run Pod; supervises the agent process and streams its output back to the controller |
| `crdgen` | Dev/CI tool: generates `deploy/crds/*.yaml` from annotated agentcore structs |
| `tsgen` | Dev/CI tool: generates `packages/agent-contracts/src/types.generated.ts` from agentcore structs |

## User Roles

| Role | Interaction |
| --- | --- |
| **Platform engineer** | Installs and upgrades the subsystem; manages cluster RBAC, secrets, NetworkPolicy |
| **Agent author** | Authors `AgentDefinition` and `Station` manifests (recipes and runtimes) |
| **Agent user** | Creates `Agent` resources (individual runs) and reads `status.output` |
| **Operator** | Monitors controller logs and Prometheus metrics; manages run pruning via Station retention settings |

## Business Rules

- An Agent run is immutable once created; the controller owns its lifecycle.
- Only the leader replica reconciles; standby replicas take over within the Lease duration on leader failure.
- `status.output` is truncated to the last `MAX_OUTPUT_BYTES` (default 256 KiB); the full log is available in the Job's Pod logs.
- Generated files (`deploy/crds/`, `packages/agent-contracts/src/types.generated.ts`) must never be edited directly; CI enforces this with a drift check.
- Every tagged release pins image digests in `deploy/` — floating tags are never used in production manifests.
- The TypeScript contracts package enforces 100% test coverage on its hand-written logic (vitest gate in CI).

## Success Metrics

- Controller reconcile loop completes without errors for all `Agent` resources in the `ai-agents` namespace.
- `make test build drift itest` passes locally and in CI on every PR.
- Installed release is reproducible via `kubectl apply -f install.yaml` with cosign-verifiable digest-pinned images.
- `@re-cinq/agent-contracts` npm package publishes on each release with version matching the git tag.
- Documentation site builds and deploys to GitHub Pages on every push to `main`.
