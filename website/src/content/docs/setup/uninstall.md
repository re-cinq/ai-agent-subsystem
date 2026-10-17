---
title: Uninstall
description: Tear the subsystem down with a single kubectl delete, and verify nothing is left behind.
---

Uninstalling is the inverse of [Install](./install.md): the same `install.yaml` (or the `deploy/`
kustomization) that stood the subsystem up also tears it down, so one `kubectl delete` removes the
controller, its RBAC and NetworkPolicy, the Custom Resource Definitions, and the namespace.

:::caution
Deleting the CRDs deletes **every** `Agent`, `Station`, `AgentDefinition`, and `ModelCatalog` in the cluster (CRDs are
cluster-scoped, not confined to `ai-agents`), which cascades their Jobs and pods. Any run in flight is
killed. There is no separate "drain" step — make sure nothing important is still running first.
:::

## Uninstall

```sh
kubectl delete -f https://github.com/re-cinq/ai-agent-subsystem/releases/latest/download/install.yaml
```

To remove a specific version you installed by digest, delete with that release's manifest:

```sh
kubectl delete -f https://github.com/re-cinq/ai-agent-subsystem/releases/download/v0.13.0/install.yaml
```

### From a source checkout

If you installed with `kubectl apply -k deploy`, delete the same kustomization:

```sh
kubectl delete -k deploy
```

### With Helm

`helm uninstall` removes the namespace and everything the chart created, but Helm never deletes
CRDs. Delete them yourself afterwards:

```sh
helm uninstall ai-agent-subsystem --namespace default
kubectl delete crd agents.agents.re-cinq.com stations.agents.re-cinq.com \
  agentdefinitions.agents.re-cinq.com modelcatalogs.agents.re-cinq.com
```

## What gets removed

- **The namespace `ai-agents`** and everything in it: the `agent-controller` Deployment, the
  controller and caller RBAC, the run-pod NetworkPolicy, and any `agent-secrets` Secret you created
  out of band. Namespace termination drains the contained objects, so this can take a moment.
- **The four CRDs** (`agents`, `stations`, `agentdefinitions`, `modelcatalogs` under `agents.re-cinq.com`) and, with
  them, all custom resources of those kinds across every namespace. Agents own their Jobs through
  owner references, so deleting an Agent garbage-collects its Job and pod.

A [batch](../tasks/batch-runs.md) Agent carries the finalizer `agents.re-cinq.com/batch-cleanup`
from submit until the controller has cancelled and deleted its provider-side batch, and only the
controller removes it. Delete batch Agents, or let them finish, before removing the
controller. If one is stuck `Terminating` once the controller is gone, remove the finalizer by hand:

```sh
kubectl -n ai-agents patch agent <name> --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

The provider-side batch is then left behind and still billed.

Credentials you created out of band are namespaced, so they go with the namespace. Nothing on the
node is touched — the subsystem mounts nothing from the host (see
[Prerequisites](./prerequisites.md#credentials)).

## Keep the CRDs, remove only the controller

To take the operator down for an upgrade or maintenance window **without** deleting in-flight runs and
their history, remove just the namespaced workload and leave the CRDs (and their custom resources)
standing:

```sh
kubectl -n ai-agents delete deploy/agent-controller
```

Re-applying `install.yaml` brings the controller back, and it reconciles whatever Agents it finds —
[Kubernetes is the only state](../concepts/architecture.md#kubernetes-as-the-control-plane).

## Verify removal

```sh
kubectl get ns ai-agents                       # "NotFound" once it finishes terminating
kubectl get crd | grep agents.re-cinq.com      # no output
```

An empty result from both means the subsystem is fully gone.
