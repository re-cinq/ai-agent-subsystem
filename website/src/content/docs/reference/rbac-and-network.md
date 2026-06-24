---
title: RBAC & network
description: The controller and caller permissions and the egress policy for run pods.
---

The subsystem ships least-privilege RBAC and a restrictive network policy for run pods.

## Controller role

The controller's ServiceAccount is granted exactly what reconciliation needs:

- **Agents**: watch, list, get, and patch (including `status`); delete (for history pruning).
- **Stations** and **AgentDefinitions**: get and list (read-only).
- **Jobs**: create and get.
- **Pods**: list and read logs (to capture `status.output`).
- **Leases** (`coordination.k8s.io`): get, create, and patch — one Lease the
  replicas contend for so only the leader reconciles (see [leader election](/concepts/controller-lifecycle/#leader-election)).

## Caller role

A separate, narrower role lets other in-cluster apps launch and inspect runs **without** touching
Jobs or pods:

- **Agents**: create, get, list, watch.

This is the role a UI or upstream pipeline binds to when it only needs to start runs and read their
status.

## Network policy for run pods

Run pods get an **egress-only** NetworkPolicy. Ingress is denied; egress is limited to:

- **DNS** (so service names resolve), and
- **HTTPS** (so the agent can reach its model provider, source forges, and registries).

The policy selects run pods by the `agents.re-cinq.com/component: job` label the
controller stamps on every run pod. It also adds `agents.re-cinq.com/agent` and
`agents.re-cinq.com/station` labels, so a run's pod is traceable with
`kubectl get pods -l agents.re-cinq.com/agent=<name>`.

```mermaid
flowchart LR
    POD["run pod"] -->|53 UDP/TCP| DNS["cluster DNS"]
    POD -->|443| NET["model provider / git / registry"]
    X(("ingress")) -. denied .-> POD
```

Tighten the HTTPS egress to specific CIDRs or an egress proxy if your environment requires it.

Run pods also run with `automountServiceAccountToken: false`: the run needs no
Kubernetes API access, so the untrusted agent code never receives a mountable API
credential.

The agent container is hardened beyond the non-root UID: `seccompProfile:
RuntimeDefault`, all Linux capabilities dropped, and `allowPrivilegeEscalation:
false`. When the Station template sets no `resources` on the agent container, the
controller fills in a default request/limit so the run is memory-bounded (not
BestEffort) and can't starve the node; set `resources` on the Station to override.
