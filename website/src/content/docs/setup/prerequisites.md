---
title: Prerequisites
description: What you need before installing ai-agent-subsystem.
---

You need a Kubernetes cluster and the usual client tooling. For local development a single-node
cluster is plenty.

## Tooling

- **`kubectl`**: configured to talk to your target cluster.
- **A Kubernetes cluster**: `v1.27+`. Any distribution works; for local use see
  [Local cluster](/setup/local-cluster/).
- **A container registry**: to host the controller and agent images, unless you side-load them into
  a local cluster.

## To build from source

The project is a D monorepo. To build the binaries yourself you need:

- **LDC** (the LLVM-based D compiler): used for static linking.
- **dub**: the D package manager and build tool.

See [Building](/contribute/building/).

## Credentials

Agents call a model provider, so the agent process needs credentials available in the Pod. Two ways
to provide them:

- **API key (any cluster):** create a namespace Secret named `agent-secrets`, then reference it from
  the recipe's `resources.secrets` (e.g. `{name: ANTHROPIC_API_KEY, ref: ANTHROPIC_API_KEY}`); the
  controller injects it as an env var via `secretKeyRef`.
- **Subscription auth (local dev):** mount your host `~/.claude` into the run container at
  `/agent/.claude` (the agent's `HOME` is `/agent`) via the Station template; no API key needed.
