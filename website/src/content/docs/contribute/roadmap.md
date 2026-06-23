---
title: Roadmap
description: What is built and what is planned.
---

The `agentcore` library, the `controller`, `supervisor`, and `initializer` binaries, the
CRD/RBAC/controller manifests under `deploy/`, and this documentation site are all in place, and the
published images are signed, SBOM-attested, and digest-pinned. For exactly what has shipped, see the
[commit history](https://github.com/re-cinq/ai-agent-subsystem/commits/main) — this page tracks
**direction**, not a feature-by-feature changelog.

## Planned / deferred

- **Production secret wiring**: replace the development host-path credentials mount with Kubernetes
  Secrets.
- **External integrations**: persisting results to a database and wiring a web UI, beyond the
  in-cluster caller API.
- **Multi-tenancy**: per-team/namespace isolation.

Have a suggestion? Open an issue on
[GitHub](https://github.com/re-cinq/ai-agent-subsystem).
