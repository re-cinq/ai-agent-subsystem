---
title: Prerequisites
description: What you need before installing ai-agent-subsystem.
---

You need a Kubernetes cluster and the usual client tooling. For local development a single-node
cluster is plenty.

## Tooling

- **`kubectl`** — configured to talk to your target cluster.
- **A Kubernetes cluster** — `v1.27+`. Any distribution works; for local use see
  [Local cluster](/setup/local-cluster/).
- **A container registry** — to host the controller and agent images, unless you side-load them into
  a local cluster.

## To build from source

The project is a D monorepo. To build the binaries yourself you need:

- **LDC** (the LLVM-based D compiler) — used for static linking.
- **dub** — the D package manager and build tool.

See [Building](/contribute/building/).

## Credentials

Agents call a model provider, so the agent process needs credentials available in the Pod. During
local development these are mounted from a host path; production secret wiring is tracked on the
[roadmap](/contribute/roadmap/).
