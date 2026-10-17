---
title: Isolate runs
description: Run every agent pod under gVisor or Kata Containers with a RuntimeClass, and what the controller enforces regardless.
---

An agent run executes code it wrote itself, often with `permission_mode: bypass`. The controller
already strips the pod of the usual escape hatches, but the run still shares the node's kernel. For a
stronger boundary, run the pod under a sandboxed container runtime: **gVisor** (a user-space kernel
that intercepts system calls) or **Kata Containers** (a lightweight VM per pod).

## Set a RuntimeClass on the Station

Isolation is a property of the run pod, so it goes on the Station's pod template.
`runtimeClassName` is passed through to every Job the Station creates, init container included:

```yaml
apiVersion: agents.re-cinq.com/v1beta1
kind: Station
metadata:
  name: story-writer-gvisor
  namespace: ai-agents
spec:
  agentDefRef: story-writer
  template:
    spec:
      runtimeClassName: gvisor          # or your Kata class, e.g. kata-qemu
      containers:
        - name: agent
          image: node:22-bookworm
```

The full file is [`examples/station-gvisor.yaml`](https://github.com/re-cinq/ai-agent-subsystem/blob/main/examples/station-gvisor.yaml).
The RuntimeClass must exist on the cluster first:

- **GKE**: enable GKE Sandbox on a node pool; it creates the `gvisor` RuntimeClass.
- **Elsewhere**: install `runsc` (gVisor) or Kata on the nodes, register it with containerd, and
  create a `RuntimeClass` whose `handler` names it. If those runtimes live only on some nodes, set
  the RuntimeClass's `scheduling.nodeSelector` so runs land there.
- **Kata** adds per-pod VM overhead. Declare it in the RuntimeClass's `overhead.podFixed` so the
  scheduler and your [limits](../set-limits/) account for it.

To confirm a run is sandboxed under gVisor, look at the kernel messages from inside the agent
container while it runs:

```sh
kubectl -n ai-agents exec <run-pod> -c agent -- dmesg | head -2   # gVisor prints "Starting gVisor..."
```

## What the controller enforces anyway

Whatever the template says, the controller builds every run pod with:

- The `agent` container running as a non-root UID with `allowPrivilegeEscalation: false`, every
  capability dropped, and the `RuntimeDefault` seccomp profile.
- `automountServiceAccountToken: false`, so the run gets no Kubernetes API credentials.
- No host access: the controller refuses to build a run pod from a template with `hostNetwork`,
  `hostPID` or `hostIPC`, a `hostPath` volume, or a privileged container. No Job is created; the
  Agent stays `Pending` and the controller log names the offending field on every retry.
- Egress limited by the subsystem's NetworkPolicy ([RBAC and network](../../reference/rbac-and-network/)).

A RuntimeClass adds a kernel boundary on top of these; it does not replace them.

## Running next to kubernetes-sigs/agent-sandbox

[agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) manages long-lived, stateful
`Sandbox` pods. Agent runs are short-lived Jobs, so the controller does not create Sandboxes, but the
two share the isolation layer: a cluster prepared for agent-sandbox already has the gVisor or Kata
RuntimeClass and node pools, and a Station that names the same `runtimeClassName` runs its agents on
them.
