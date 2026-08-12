---
title: Prerequisites
description: What you need before installing ai-agent-subsystem.
---

You need a Kubernetes cluster and the usual client tooling. For local development a single-node
cluster is plenty.

## Tooling

- **`kubectl`**: configured to talk to your target cluster.
- **A Kubernetes cluster**: `v1.27+`. Any distribution works; for local use see
  [Local cluster](./local-cluster.md).
- **A container registry**: only if you build your own images. The published controller and agent
  images are public, so a normal install pulls them with no registry, credentials or side-loading of
  your own.

## To build from source

The project is a D monorepo. To build the binaries yourself you need:

- **LDC** (the LLVM-based D compiler): used for static linking.
- **dub**: the D package manager and build tool.

See [Building](../contribute/building.md).

## Credentials

Agents call a model provider, so the agent process needs credentials available in the Pod. There is
one supported way to provide them: create a namespace Secret named `agent-secrets`, then reference
its keys from the recipe's `resources.secrets` (e.g.
`{name: ANTHROPIC_API_KEY, ref: ANTHROPIC_API_KEY}`). The controller injects each entry as a
container env var via `secretKeyRef`, sourced from that single Secret. See
[Launch an agent](../tasks/launch-an-agent.md#verify-api-key-auth-end-to-end).

:::note
Earlier versions suggested mounting your host `~/.claude` into the run container for subscription
auth during local development. That no longer works: the `ai-agents` namespace enforces Pod Security
Admission at `baseline`, which rejects `hostPath` volumes — deliberately, since the Station
template's preserve-unknown-fields passthrough would otherwise leave that escape hatch open. Use an
API key in `agent-secrets` on every cluster, local included.
:::
