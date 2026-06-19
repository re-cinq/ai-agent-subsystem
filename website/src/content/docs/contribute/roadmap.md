---
title: Roadmap
description: What is built, what is in progress, and what is deferred.
---

This phase delivers the documentation and project scaffold. The D implementation follows, guided by
these docs.

## Done

- Documentation site (concepts, setup, tasks, reference) with relationship diagrams.
- Project scaffold and GitHub Pages deployment.

## In progress

- The `agentcore` shared library: CRD types, Kubernetes client, reconcile state machine, prompt
  templating, Job builder.
- The `controller` and `supervisor` binaries.
- CRD, RBAC, and controller manifests under `deploy/`.

## Deferred

- **Production secret wiring** — replace the development host-path credentials mount with Kubernetes
  Secrets.
- **Image publishing** — build and push the controller and agent images to a registry.
- **External integrations** — persisting results to a database and wiring a web UI, beyond the
  in-cluster caller API.
- **Multi-tenancy** — per-team/namespace isolation.

Have a suggestion? Open an issue on
[GitHub](https://github.com/re-cinq/ai-agent-subsystem).
