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
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/batch?ref=v0.12.0
```

The grant is a tradeoff. Without it only run pods ever see provider keys; with it the controller can
read every key in `agent-secrets`, though it only reads the key a batch definition maps in
`resources.secrets`. Leave the component out if you never use `execution: batch`; batch Agents then
fail with `batch execution is disabled on this controller`.

## Caller role

A separate, narrower role lets other in-cluster apps launch and inspect runs **without** touching
Jobs or pods:

- **Agents**: create, get, list, watch.

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

## Controller egress for batch runs

The NetworkPolicy above selects run pods only. The controller pod is not selected by it, so its
egress is whatever your cluster allows by default; with no other policy in place, it can already
reach `api.anthropic.com` on 443. For batch runs the controller itself calls the Anthropic Message
Batches API (`https://api.anthropic.com/v1/messages/batches`) to submit, poll, cancel and delete
batches. If you restrict the controller's egress, allow HTTPS to `api.anthropic.com`. OpenAI and
Gemini batch support is coming and will need `api.openai.com` and
`generativelanguage.googleapis.com`.

The controller polls each in-flight batch at most once every `BATCH_POLL_SECONDS` seconds (default
`60`), set as an environment variable on the controller Deployment.

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
