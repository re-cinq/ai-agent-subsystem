---
title: Realtime sessions
description: Keep an agent running and send it prompts over HTTP, then resume the conversation later.
---

A realtime session keeps the agent CLI running in its run pod and takes prompts over HTTP, one turn at
a time, until you close it or it sits idle. When it ends, it saves the conversation under its session
id, and a later Agent can pick up where it left off. An AgentDefinition with `execution: realtime` runs
this way.

Use it when the next prompt depends on a person or another system reacting to the last answer: a chat
front end, a review loop, a workflow that feeds the agent results as they arrive. Keep interactive
execution for work that fits in one prompt.

## Enable realtime on the controller

Realtime is off by default, and a realtime Agent then fails with
`realtime execution is disabled on this controller`. To turn it on:

1. Create the `agent-realtime` Secret. `api-token` is the bearer callers send to the prompt API, and
   `signing-key` is the key the controller derives each run's own token from:

   ```sh
   kubectl -n ai-agents create secret generic agent-realtime \
     --from-literal=api-token="$(openssl rand -hex 32)" \
     --from-literal=signing-key="$(openssl rand -hex 32)"
   ```

2. Add the `deploy/components/realtime` kustomize component next to the base install, and apply it with
   `kubectl apply -k .`:

   ```yaml
   # kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deploy
   components:
     - deploy/components/realtime
   ```

   From a release, use the release URLs instead
   (`https://github.com/re-cinq/ai-agent-subsystem//deploy?ref=v0.12.0` and
   `https://github.com/re-cinq/ai-agent-subsystem//deploy/components/realtime?ref=v0.12.0`, with the
   release you install). The release `install.yaml` does not include the component.

The component makes these changes:

| Change | What it does |
| --- | --- |
| Controller env from the Secret | `REALTIME_API_TOKEN` and `REALTIME_SIGNING_KEY`, plus `REALTIME_API_PORT=8082` |
| Service `agent-controller-api` | Exposes the prompt API on port 8082. Every controller replica serves it, leader or not. |
| NetworkPolicy `agent-job-realtime-ingress` | Lets controller pods, and nothing else, reach port 8090 on realtime run pods. Every other ingress to run pods stays denied. |

## Define a realtime recipe

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: AgentDefinition
metadata: { name: pair-reviewer, namespace: ai-agents }
spec:
  model: claude-sonnet-4-6
  prompt: "Review the diff in {pr}. Wait for my questions afterwards."
  execution: realtime
  realtime:
    idleTimeoutMinutes: 20
  resources:
    conversation:
      source: https://conversations.example.com/state   # where sessions are saved and restored
    secrets:
      - { name: ANTHROPIC_API_KEY, ref: anthropic-key }
```

The rendered `prompt` is the session's first turn. Set `prompt: ""` to start with no turn and wait for
the first HTTP prompt. `resources.conversation` takes only `source` (and `headers_secret`), because the
session saves under its own id; a realtime definition that sets `id` or `pin` fails.

The Station's `deadlineMinutes` is still the hard limit, so set it above the longest session you expect.

## Send prompts

Start an Agent on a Station that uses the definition, as for any run. Once it is `Running`, post
prompts to the controller. This example port-forwards the Service; in-cluster callers can use
`http://agent-controller-api.ai-agents:8082` directly.

```sh
kubectl -n ai-agents port-forward svc/agent-controller-api 8082:8082 &
TOKEN="$(kubectl -n ai-agents get secret agent-realtime -o jsonpath='{.data.api-token}' | base64 -d)"

curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"prompt":"Which change is the riskiest?"}' \
  http://127.0.0.1:8082/v1/namespaces/ai-agents/agents/review-42/prompt
```

```json
{ "turn": 2, "queued": 1, "sessionId": "0f8c2a4e-5b7d-4c1e-9a3f-2d6b8e1c7a90" }
```

A 202 means the prompt is queued, not answered. The answer reaches the definition's
[output sinks](./collect-output.md) and the pod log like any other run's events, between a
`{"kind":"turn","turn":2,"status":"started"}` and a `{"kind":"turn","turn":2,"status":"completed","ok":true}`
event. Prompts run one at a time, in the order they arrived. While the pod is still starting, the API
answers 503 with `Retry-After: 2`. Every status code is listed in the [prompt API reference](../reference/prompt-api.md).

## End the session

A session ends in one of these ways:

| Trigger | Result |
| --- | --- |
| `POST …/close` | New prompts, and a second close, are refused with 409. The queued turns run, then the session ends. Agent `Succeeded`. |
| No prompt and no running turn for `realtime.idleTimeoutMinutes` (default 15) | Agent `Succeeded`. |
| The pod is sent SIGTERM (for example, a node drain) | The session ends at once: queued turns are dropped, a running turn gets the exit grace period and is then stopped, and the supervisor exits 0. |
| The Station's `deadlineMinutes` passes | Agent `Failed`, exit code 124. |
| The Claude CLI exits by itself | The Agent takes the CLI's exit code. |

Before the pod exits, the supervisor saves the conversation to `<source>/<session id>` when three
things hold: the definition sets `resources.conversation.source`, the session id is known, and the
vendor keeps conversation state. opencode and `exec` never save. A Codex or Gemini session learns its id
from its first turn, so one closed before any turn ran saves nothing and records no `status.sessionId`.
A fresh Claude session's id is the Agent's `metadata.uid`, known from the start.

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8082/v1/namespaces/ai-agents/agents/review-42/close
```

## Resume a session

Pass the earlier run's `status.sessionId` as `spec.resumeSession` on a new Agent, on a Station (here
`pair-reviewer`) whose definition is the realtime recipe:

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: Agent
metadata: { name: review-42-day2, namespace: ai-agents }
spec:
  stationRef: pair-reviewer
  resumeSession: 0f8c2a4e-5b7d-4c1e-9a3f-2d6b8e1c7a90
```

The controller fails the Agent before it starts with `resumeSession requires realtime execution`,
`resumeSession needs resources.conversation.source` or `<vendor> cannot resume a session` when the
recipe cannot resume. Otherwise the init container restores `<source>/<id>` before the agent starts. The definition's prompt is **not**
sent: the session waits for your first HTTP prompt. When it ends, it saves back under the same id, so
the next resume continues from there.

## How each vendor runs a session

| Vendor | How turns run | Resume |
| --- | --- | --- |
| Claude | One process for the whole session, each prompt sent as a `stream-json` line on stdin | Same session id |
| Codex | One `codex exec` per turn; later turns run `codex exec resume <thread id>` | Codex may report a new thread id after a resume. `status.sessionId` follows the last one. |
| Gemini | One process per turn; later turns run `--resume latest` | Same restored state |
| opencode, `exec` | One fresh process per turn, with no memory of earlier turns. The session raises an `agent`/`running` event with reason `no-continuity`. | Not supported: `resumeSession` fails with `<vendor> cannot resume a session` |

## Limits

- An open session holds a Station slot until it ends, idle time included. Under
  `concurrencyPolicy: Replace` a new Agent preempts the oldest run, even if that run is a live session.
- The conversation is saved only when the session ends. If the node is lost, the pod is killed without
  SIGTERM, and the conversation is lost.
- A prompt can be at most 100 KiB, and at most 16 prompts can wait in the queue (429 past that).
- `status.output` keeps only the tail of a long session's log; use sinks for the full stream.
- Every caller shares the one `api-token` and can prompt any realtime Agent in the namespace.
