---
title: Roadmap
description: What is built, what is in progress, and what is deferred.
---

This phase delivers the documentation and project scaffold. The D implementation follows, guided by
these docs.

## Done

- Documentation site (concepts, setup, tasks, reference) with relationship diagrams.
- Project scaffold and GitHub Pages deployment.
- The `agentcore` shared library: CRD types, reconcile state machine, prompt templating, Job builder,
  and the in-cluster Kubernetes client.
- The `controller`, `supervisor`, and `initializer` binaries, with the controller's watch + poll
  reconcile loop, Job ownership/pruning, credential injection, and `/healthz`.
- The `ai-agent` runtime image: the init container stages the supervisor into the run bundle, clones
  repos, and installs the agent CLI.
- CRD, RBAC, and controller manifests under `deploy/`.

## In progress

- Cross-distro container tests and CI for the controller + `ai-agent` image.
- `output.select` event filtering (needs per-provider event normalization).

## Deferred

- **Production secret wiring** — replace the development host-path credentials mount with Kubernetes
  Secrets.
- **Image publishing** — build and push the controller and agent images to a registry.
- **External integrations** — persisting results to a database and wiring a web UI, beyond the
  in-cluster caller API.
- **Multi-tenancy** — per-team/namespace isolation.

Have a suggestion? Open an issue on
[GitHub](https://github.com/re-cinq/ai-agent-subsystem).
