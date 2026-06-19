---
title: Create a station
description: Pair a recipe with a Pod template by defining a Station.
---

A [Station](/concepts/station/) pairs an
[AgentDefinition](/concepts/agentdefinition/) with the Pod it runs in. The
controller injects the agent runtime, so the container image only needs to be glibc-based.

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: Station
metadata:
  name: node-fixer
spec:
  agentDefRef: bug-fixer
  deadlineMinutes: 15
  successfulRunsHistoryLimit: 3
  failedRunsHistoryLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: agent
          image: debian:bookworm-slim
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
```

## Notes

- **`agentDefRef`** must match the name of an existing `AgentDefinition`.
- The container named **`agent`** is the one the controller wires with the rendered prompt and the
  injected supervisor. You do not set its `command` — the controller overrides it.
- **`deadlineMinutes`** becomes the Job's `activeDeadlineSeconds`.
- **History limits** bound how many finished Agents the controller keeps per phase.

Apply it:

```sh
kubectl apply -f node-fixer.yaml
kubectl get stations
```

Now launch a run in [Launch an agent](/tasks/launch-an-agent/).
