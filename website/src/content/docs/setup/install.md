---
title: Install
description: Apply the CRDs, RBAC, and controller, then verify the deployment.
---

Installation applies the Custom Resource Definitions, the controller's RBAC, and the controller
Deployment into a dedicated namespace.

:::note
The manifests and images are produced by the implementation phase that these docs specify. This page
describes the intended install flow.
:::

## 1. Create the namespace and CRDs

```sh
kubectl apply -f deploy/namespace.yaml
kubectl apply -f deploy/crds/
```

Confirm the CRDs registered:

```sh
kubectl get crds | grep agents.re-cinq.com
```

## 2. Apply RBAC and the controller

```sh
kubectl apply -f deploy/rbac/
kubectl apply -f deploy/controller.yaml
```

The controller runs least-privilege: it can watch and patch Agents, read Stations and
AgentDefinitions, manage Jobs, and read pod logs. See
[RBAC & network](/ai-agent-subsystem/reference/rbac-and-network/).

## 3. Verify

```sh
kubectl -n ai-agents get deploy,pods
kubectl -n ai-agents logs deploy/agent-controller
```

The controller exposes `/healthz` on its health port; a `Running` pod with passing probes means it
is reconciling.

## Next

Define your first recipe in [Define a recipe](/ai-agent-subsystem/tasks/define-a-recipe/), or jump
straight to the [Examples](/ai-agent-subsystem/tasks/examples/).
