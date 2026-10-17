---
title: Local cluster
description: Stand up a local Kubernetes cluster for development with kind or minikube.
---

## One command: `make demo`

From a checkout, with Docker and either kind or minikube installed:

```sh
make demo                                   # kind; CLUSTER_TOOL=minikube for minikube
```

It builds the images, creates a cluster named `agent-demo`, installs the subsystem from `deploy/`,
and runs the [story-writer example](../tasks/examples.md), printing the agent's output when the
run reaches `Succeeded`. With `ANTHROPIC_API_KEY` set in your shell, the run calls the real model;
without it (or with `MOCK=1`), a deterministic mock agent stands in, so the demo needs no key and no
network from the run pod.

| Variable | Effect |
| --- | --- |
| `CLUSTER_TOOL` | `kind` (default) or `minikube`. Use minikube where kind's containerd OOMs the init container. |
| `CLUSTER` | Cluster or profile name, default `agent-demo`. |
| `EXAMPLES` | Space-separated names from `examples/*.yaml`, or `all`. Default `story-writer`. |
| `KEEP=1` | Keep the cluster afterwards (it is deleted by default). |
| `REBUILD=1` | Rebuild the images even if they exist locally. |
| `MOCK=1` | Use the mock agent even when `ANTHROPIC_API_KEY` is set. |

CI runs `make itest-examples`, which is `MOCK=1 EXAMPLES=all make demo`: every example is
schema-checked against the CRDs and run end to end, so a broken example fails the build.

## By hand

Any local Kubernetes works. The two most common choices are **kind** and **minikube**. The
controller auto-detects whether it runs in-cluster or against a local kubeconfig, so the same image
works in both.

### kind

```sh
kind create cluster --name ai-agents
kubectl config use-context kind-ai-agents
```

Because the agent runtime is injected at run time, your Station images only need to be glibc-based
(for example `debian:bookworm-slim`). Load locally built images into the cluster with:

```sh
kind load docker-image ai-agent:dev --name ai-agents
```

### minikube

```sh
minikube start -p ai-agents
kubectl config use-context ai-agents
```

To use locally built images without a registry, build against minikube's Docker daemon:

```sh
eval "$(minikube -p ai-agents docker-env)"
# docker build ... ai-agent:dev
```

## Next

With a cluster running, continue to [Install](./install.md).
