---
title: RBAC & network
description: The controller and caller permissions and the egress policy for run pods.
---

The subsystem ships least-privilege RBAC and a restrictive network policy for run pods.

## Controller role

The controller's ServiceAccount is granted exactly what reconciliation needs:

- **Agents**: watch, list, get, and patch (including `status`); delete (for history pruning);
  create (for the runs an [AgentSpawner](./crd-agentspawner.md) starts).
- **AgentSpawners**: get, list and watch, and patch on `status` (to record the last schedule time).
- **Stations** and **AgentDefinitions**: get and list (read-only).
- **ModelCatalogs**: get, create, and patch (including `status`), to server-side apply the
  [ModelCatalog](./crd-modelcatalog.md) when the model catalog component is enabled.
- **Jobs**: create and get.
- **Pods**: list and read logs (to capture `status.output`).
- **Leases** (`coordination.k8s.io`): get, create, and patch — one Lease the
  replicas contend for so only the leader reconciles (see [leader election](../concepts/controller-lifecycle.md#leader-election)).
The default install grants **no access to Secrets**: run pods receive provider keys through
`secretKeyRef`, which the kubelet resolves.

### Batch component (opt-in)

[Batch runs](../tasks/batch-runs.md#enable-batch-on-the-controller) need the controller to read the
provider API key itself. The `deploy/components/batch` kustomize component adds a separate
`agent-controller-batch` Role and RoleBinding with `get` on the `agent-secrets` Secret only
(`resourceNames: ["agent-secrets"]`), and sets `BATCH_ENABLED=true` on the controller. The controller
still cannot list Secrets or read any other one.

```yaml
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/batch?ref=v0.13.0
```

The grant is a tradeoff. Without it only run pods ever see provider keys; with it the controller can
read every key in `agent-secrets`, though it only reads the key a batch definition maps in
`resources.secrets`. Leave the component out if you never use `execution: batch`; batch Agents then
fail with `batch execution is disabled on this controller`.

### Model catalog component (opt-in)

The [ModelCatalog](./crd-modelcatalog.md) is filled by the controller calling each vendor's
list-models API with the keys AgentDefinitions map from `agent-secrets`. The
`deploy/components/model-catalog` kustomize component adds a separate
`agent-controller-model-catalog` Role and RoleBinding with `get` on the `agent-secrets` Secret only,
and sets `MODEL_CATALOG_ENABLED=true`. The tradeoff is the same as for
the batch component. Without it the controller does nothing for the catalog.

```yaml
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/model-catalog?ref=v0.13.0
```

### Realtime component (opt-in)

[Realtime sessions](../tasks/realtime-sessions.md) need no extra RBAC. The
`deploy/components/realtime` component sets `REALTIME_API_TOKEN` and `REALTIME_SIGNING_KEY` on the
controller from the `agent-realtime` Secret (by `secretKeyRef`, so the controller still reads no
Secret itself), opens the [prompt API](./prompt-api.md) on port 8082 behind the
`agent-controller-api` Service, and adds the `agent-job-realtime-ingress` NetworkPolicy described
[below](#network-policy-for-run-pods).

## Caller role

A separate, narrower role lets other in-cluster apps launch and inspect runs **without** touching
Jobs or pods:

- **Agents**: create, get, list, watch.
- **AgentSpawners**: create, get, list, watch, update, patch, delete, to [schedule runs](../tasks/schedule-runs.md).
  The controller creates the scheduled Agents, so this grants nothing beyond creating Agents directly.
- **ModelCatalogs**: get, list, watch, to discover which models the subsystem can run (see
  [ModelCatalog](./crd-modelcatalog.md)).

This is the role a UI or upstream pipeline binds to when it only needs to start runs and read their
status.

## Network policy for run pods

Run pods get an **egress-only** NetworkPolicy. Ingress is denied; egress is limited to:

- **DNS to the in-cluster resolver only** (CoreDNS/kube-dns) — so untrusted code can't tunnel data
  out through an arbitrary external resolver. This assumes the standard
  `kube-system` / `k8s-app=kube-dns` labels; adjust it for a non-standard DNS setup.
- **HTTPS to the public internet** (model provider, source forges, registries), **excluding** RFC1918
  private ranges and link-local `169.254.0.0/16` — so the agent can't reach cluster-internal services
  (SSRF) or steal credentials from the cloud metadata endpoint `169.254.169.254`.

With the realtime component, a second policy, `agent-job-realtime-ingress`, admits ingress to run pods
labelled `agents.re-cinq.com/execution: realtime` from controller pods only, on TCP 8090, where the
supervisor takes prompts. Policies add up, so every other ingress stays denied. Where the CNI does not
enforce NetworkPolicy, the supervisor still refuses any request without the run's own token.

The policy selects run pods by the `agents.re-cinq.com/component: job` label the
controller stamps on every run pod. It also adds `agents.re-cinq.com/agent` and
`agents.re-cinq.com/station` labels, so a run's pod is traceable with
`kubectl get pods -l agents.re-cinq.com/agent=<name>`.

```mermaid
flowchart LR
    POD["run pod"] -->|53 UDP/TCP| DNS["cluster DNS only"]
    POD -->|"443 (public, no RFC1918 / metadata)"| NET["model provider / git / registry"]
    POD -. blocked .-> INT["cluster-internal / 169.254.169.254"]
    X(("ingress")) -. denied .-> POD
```

## Controller egress

The NetworkPolicy above selects run pods only. The controller pod is not selected by it, so its
egress is whatever your cluster allows by default; with no other policy in place, it can already
reach the providers on 443. For batch runs the controller itself calls the Anthropic Message
Batches API (`https://api.anthropic.com/v1/messages/batches`) for Claude models and the Gemini
Batch API (`https://generativelanguage.googleapis.com/v1beta/`) for Gemini models and the OpenAI
Batch and Files APIs (`https://api.openai.com/v1/batches`, `https://api.openai.com/v1/files`) for
Codex-routed models to submit, poll, cancel and delete batches. If you restrict the controller's
egress, allow HTTPS to `api.anthropic.com`, `generativelanguage.googleapis.com` and
`api.openai.com` (only the ones whose models you batch).

The controller polls each in-flight batch at most once every `BATCH_POLL_SECONDS` seconds (default
`60`), set as an environment variable on the controller Deployment.

With the model catalog component, the controller also calls the list-models endpoints of the vendors
whose keys AgentDefinitions map: `api.anthropic.com`, `api.openai.com` and
`generativelanguage.googleapis.com`. Allow HTTPS to the ones you use if you restrict the controller's
egress.

Tighten the HTTPS egress further — to specific provider CIDRs or through an egress proxy — if your
environment allows.

Run pods also run with `automountServiceAccountToken: false`: the run needs no
Kubernetes API access, so the untrusted agent code never receives a mountable API
credential.

The agent container is hardened beyond the non-root UID: `seccompProfile:
RuntimeDefault`, all Linux capabilities dropped, and `allowPrivilegeEscalation:
false`. When the Station template sets no `resources` on the agent container, the
controller fills in a default request/limit so the run is memory-bounded (not
BestEffort) and can't starve the node; set `resources` on the Station to override.
