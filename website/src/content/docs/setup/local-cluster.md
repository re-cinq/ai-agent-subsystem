---
title: Local cluster
description: Stand up a local Kubernetes cluster for development with kind or minikube.
---

Any local Kubernetes works. The two most common choices are **kind** and **minikube**. The
controller auto-detects whether it runs in-cluster or against a local kubeconfig, so the same image
works in both.

## kind

```sh
kind create cluster --name ai-agents
kubectl config use-context kind-ai-agents
```

Because the agent runtime is injected at run time, your Station images only need to be glibc-based
(for example `debian:bookworm-slim`). Load locally built images into the cluster with:

```sh
kind load docker-image ai-agent:dev --name ai-agents
```

## minikube

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
