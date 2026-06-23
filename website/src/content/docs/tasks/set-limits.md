---
title: Setting limits
description: Bound an Agent run's resources and wall-clock, cap how many run at once, and put a ceiling on the whole namespace.
---

Limits live at two levels: **per run** (on the Station) and a **namespace ceiling**
(standard Kubernetes objects). Use both: the Station shapes each run, the namespace
caps the blast radius.

## Per-run limits: on the Station

Set them on the `Station`. The controller wires the container named `agent` (command,
env, mounts) but **preserves whatever else you set on it**, including `resources`.

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: Station
metadata:
  name: node-fixer
  namespace: ai-agents
spec:
  agentDefRef: bug-fixer
  deadlineMinutes: 15            # per-run wall-clock -> Job activeDeadlineSeconds
  maxConcurrentRuns: 3           # at most 3 runs of THIS Station at once (0 = unlimited)
  successfulRunsHistoryLimit: 3  # finished Agents kept before pruning (retention, not concurrency)
  failedRunsHistoryLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: agent
          image: node:22-bookworm
          resources:             # per-run CPU/memory, set these yourself
            requests:
              cpu: "500m"
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
```

| Field | Effect |
| --- | --- |
| `resources` (on the `agent` container) | CPU/memory requests + limits for the run. **The controller does not default these**: only the init container is defaulted, so set them here or use a `LimitRange` (below). |
| `deadlineMinutes` | Wall-clock limit per run; becomes the Job's `activeDeadlineSeconds`. |
| `maxConcurrentRuns` | How many Agents of this Station may be `Running` at once. `0` (default) is unlimited. A new `Agent` created while the Station is at the limit stays `Pending` and starts automatically once a run finishes. |
| `successfulRunsHistoryLimit` / `failedRunsHistoryLimit` | How many **finished** Agents are kept per phase before the oldest are pruned. Retention only, unrelated to concurrency. |

## How concurrency works

The controller counts the Station's Agents currently in `Running`. While that count is
at `maxConcurrentRuns`, any `Pending` Agent for the Station **waits** (it is not failed
or dropped) and is admitted on the next reconcile once a run completes. So you can queue
work freely: create as many Agents as you like, and the Station drains them
`maxConcurrentRuns` at a time. `maxConcurrentRuns: 1` gives strict serial execution.

## Namespace ceiling: bound the whole namespace

`maxConcurrentRuns` caps one Station; a `ResourceQuota` caps everything in the namespace,
so a burst across many Stations can't exhaust the cluster.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata: { name: agent-runs, namespace: ai-agents }
spec:
  hard:
    requests.cpu: "10"      # 10 CPU / 500m-per-run ~= 20 concurrent runs
    requests.memory: 20Gi
    limits.cpu: "40"
    limits.memory: 80Gi
```

A `LimitRange` gives default container limits, so a Station that forgets `resources`
isn't scheduled as BestEffort (the first thing the kernel OOM-kills):

```yaml
apiVersion: v1
kind: LimitRange
metadata: { name: agent-defaults, namespace: ai-agents }
spec:
  limits:
    - type: Container
      default:        { cpu: "1",   memory: 1Gi }
      defaultRequest: { cpu: "250m", memory: 256Mi }
```

```sh
kubectl apply -f quota.yaml -f limitrange.yaml
```

A `ResourceQuota` counts **every** pod in the namespace, including the controller. To
keep the math clean, run agents in a dedicated namespace so the quota only counts run
pods.
