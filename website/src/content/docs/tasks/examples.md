---
title: Examples
description: "Two worked end-to-end examples: a code-editing bug-fixer and a pure-text story writer."
---

Two complete examples show the range: one edits code with tools, the other just generates text.

:::tip[Ready to apply]
These are available as runnable files in the
[`examples/`](https://github.com/re-cinq/ai-agent-subsystem/tree/main/examples) directory, with a
`run-agent.sh` launcher and an `http`-sink listener. Grab them and
`kubectl apply -f examples/story-writer.yaml`.
:::

## Bug-fixer (code editing)

A recipe that fixes a referenced ticket, with tool permissions scoped to reading, editing, and
running tests.

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: AgentDefinition
metadata:
  name: bug-fixer
spec:
  model: claude-sonnet-4-6
  prompt: |
    Fix bug {ticket} on repository {repo}, branch {branch}.
    Keep the change minimal and the tests green.
  permission_mode: auto
  allowed_tools: [Read, Edit, "Bash(npm run test:*)"]
  max_turns: 40
  output:
    format: stream-json
    sinks:
      - type: stdout
---
apiVersion: agents.re-cinq.com/v1alpha1
kind: Station
metadata:
  name: node-fixer
spec:
  agentDefRef: bug-fixer
  deadlineMinutes: 15
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: agent
          image: debian:bookworm-slim
```

Launch a run:

```sh
kubectl create -f - <<'EOF'
apiVersion: agents.re-cinq.com/v1alpha1
kind: Agent
metadata:
  generateName: bug-fixer-run-
spec:
  stationRef: node-fixer
  parameters:
    ticket: ENG-417
    repo: re-cinq/ai-agent-subsystem
    branch: fix/login-eng-417
EOF
```

## Story writer (pure text)

No tools, no repo: just prompt in, text out, streamed to an http sink.

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: AgentDefinition
metadata:
  name: story-writer
spec:
  model: claude-sonnet-4-6
  prompt: |
    Write an evocative opening paragraph for a story titled "{title}".
  permission_mode: bypass
  output:
    format: stream-json
    sinks:
      - type: stdout
      - type: http
        url: http://collector.ai-agents.svc:8099/notify
---
apiVersion: agents.re-cinq.com/v1alpha1
kind: Station
metadata:
  name: writer
spec:
  agentDefRef: story-writer
  deadlineMinutes: 5
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: agent
          image: debian:bookworm-slim
```

```sh
kubectl create -f - <<'EOF'
apiVersion: agents.re-cinq.com/v1alpha1
kind: Agent
metadata:
  generateName: story-run-
spec:
  stationRef: writer
  parameters:
    title: The Last Lighthouse
EOF
```

Watch either run with `kubectl get agents -w` and collect results as described in
[Collect output](./collect-output.md).
