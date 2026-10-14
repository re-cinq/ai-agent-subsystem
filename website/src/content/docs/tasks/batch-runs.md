---
title: Batch runs
description: Run a single-call recipe through the provider's batch API for about half the price.
---

Provider batch APIs cost about 50% less than the regular API, but a result can take up to 24 hours
and each request is one model call with no tool loop. An AgentDefinition with `execution: batch`
uses this path. No Job or pod is created: the controller submits the prompt, polls the batch from
its reconcile loop, and records the result on the Agent.

Batch runs support Anthropic (Claude models) today. OpenAI and Gemini batch support is coming.

## Enable batch on the controller

Batch execution is off by default. The controller then holds no access to Secrets, and a batch
Agent fails with `batch execution is disabled on this controller`. Disabling batch while runs
are in flight fails those Agents the same way, with an `agent`/`failed` event to their sinks. With
no provider access the controller cannot cancel or delete their batches: it releases the
`agents.re-cinq.com/batch-cleanup` finalizer, and the provider-side batches run to completion and
expire on their own, and are still billed. To turn it on, add the
`components/batch` kustomize component next to the base install. It grants the controller `get`
on the `agent-secrets` Secret (that Secret only) and sets `BATCH_ENABLED=true` on the controller
Deployment:

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy?ref=v0.12.0
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/batch?ref=v0.12.0
```

From a checkout, use the local paths instead (`resources: [deploy]`, `components:
[deploy/components/batch]`). Apply it with `kubectl apply -k .`. The release `install.yaml` does
not include the component.

## When to use it

Use batch for work that fits in one prompt and one answer and can wait: classifying or summarising
documents, drafting text from parameters, reviewing a diff passed in the prompt. Keep interactive
execution for anything that needs tools, a checked-out repository, several turns or a fast answer.

A batch definition may not set any field that needs the CLI harness. The Agent fails with
`batch execution does not support <field>` when the definition sets:

- `allowed_tools`, `disallowed_tools` or `max_turns`
- `resources.repos`, `resources.mcp_servers`, `resources.skills` or `resources.conversation`
- `output.watch`
- the `exec` model, or a model that does not route to Claude (Codex, Gemini or opencode models)

The Agent itself may not set `spec.files` (`batch execution does not support files`). An Agent's
`spec.model` overrides the definition's model as it does for a Job, and the override goes through the
same model check.

The full rules are in the [AgentDefinition reference](../reference/crd-agentdefinition.md#batch-validation).

## Example

The controller reads the API key from the `agent-secrets` Secret, through the definition's
`resources.secrets` entry named `ANTHROPIC_API_KEY`, the same entry a CLI run uses:

```sh
kubectl -n ai-agents create secret generic agent-secrets \
  --from-literal=anthropic-key="$ANTHROPIC_API_KEY"
```

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: AgentDefinition
metadata:
  name: ticket-summary
  namespace: ai-agents
spec:
  description: Summarise a support ticket in three sentences.
  model: claude-sonnet-4-6
  execution: batch
  batch:
    timeoutMinutes: 720
    onTimeout: fail
  prompt: |
    Summarise this support ticket in three sentences for the on-call engineer:
    {ticket}
  resources:
    secrets:
      - name: ANTHROPIC_API_KEY
        ref: anthropic-key
---
apiVersion: agents.re-cinq.com/v1alpha1
kind: Station
metadata:
  name: ticket-summary
  namespace: ai-agents
spec:
  agentDefRef: ticket-summary
  maxConcurrentRuns: 20
  template:
    spec:
      containers:
        - name: agent
          image: node:22-bookworm-slim
---
apiVersion: agents.re-cinq.com/v1alpha1
kind: Agent
metadata:
  generateName: ticket-summary-
  namespace: ai-agents
spec:
  stationRef: ticket-summary
  parameters:
    ticket: "Login page returns 500 after the 2.3 deploy for users with SSO enabled."
```

The Station's `template` is still required. The batch request does not use it, but a run that
[falls back](#timeouts-and-fallback) to a Job does.

Create the Agent and watch it:

```sh
kubectl create -f ticket-summary-agent.yaml
kubectl -n ai-agents get agents -w
```

The Agent goes `Pending`, then `Running` with `status.batchId` and `status.batchProvider: anthropic`
set, then `Succeeded` or `Failed` once the batch ends.

## What the request contains

The controller sends one request per Agent. The prompt is the definition's `prompt` rendered with
the Agent's `parameters`, the model is the Agent's `spec.model` when set and the definition's `model`
otherwise, and the request's `custom_id` is the Agent's uid. When neither names a model, the request
uses `claude-opus-5-5`: unlike the CLI, a batch request has no default model of its own.

`batch.maxTokens` sets the request's `max_tokens` (default `16000`). Models that always think, such
as `claude-opus-5-5`, spend part of it on thinking, so raise it for long answers.

An `output.schema` on the definition becomes structured output: the request carries
`output_config: {format: {type: json_schema, schema: <your schema>}}`, and the model's answer, in the
`result` event's `result` field, is JSON that matches the schema.

## Where the result goes

When the batch ends, the controller writes `status.output` with the lines the Claude CLI prints for a
single-turn, no-tool run: a `system` init event, an `assistant` message, and a `result` event with
`is_error`, `result`, `usage`, `modelUsage`, `total_cost_usd` and `session_id`. These carry every field
of the [consumer contract](../reference/notification-api.md#consumer-contract), with the same types
as a CLI run. The batch API reports no timing, so
the durations are `0`. `usage` is the provider's token counts, including
`cache_creation_input_tokens` and `cache_read_input_tokens` when the provider reports them.

`total_cost_usd` is computed by the controller: half the standard per-token price of the model
(the batch discount) for the input and output tokens. Cache tokens are not priced. The price table
is fixed in the controller (Anthropic list prices as of 2026-10) and matches model ids exactly; a
model that is not in it, such as a dated snapshot id, reports `0`.

If the response has `thinking` blocks before the answer, as it always does for models that always
think, they are dropped: the `assistant` event carries only the `text` blocks, as the CLI prints
it, and `result` is those blocks' text joined together. Anything that already parses a CLI
run's `status.output` parses a batch run's the same way. The output is capped at `MAX_OUTPUT_BYTES`
like a pod's log.

## Sinks

The controller delivers a batch run's events to the definition's `output.sinks` itself, in the same
`{"source", "event"}` envelope a pod run's supervisor uses. `source` carries the Agent's `agent`,
`station`, `task` and `namespace`; `pod` is absent, since there is no pod. A listener sees:

1. `{"kind":"lifecycle","phase":"agent","status":"started"}` once the batch is submitted.
2. When the batch ends, each CLI line from `status.output` that passes `output.select`, then
   `agent`/`succeeded` with `exitCode: 0`, or `agent`/`failed` with `exitCode: 1` and
   `reason: "batch_failed"`.
3. On a timeout with `onTimeout: fail`, `agent`/`failed` with `exitCode: 1` and
   `reason: "batch_timeout"`. With `onTimeout: fallback`, `agent`/`running` with
   `reason: "batch_timeout"`, which does not end the run: the fallback Job's own init and supervisor
   events follow, including its `agent`/`succeeded` or `agent`/`failed`.

An http sink's `headers_secret` is read by the controller from the same key of `agent-secrets`, so
batch runs need the `components/batch` Secret grant they already use for the API key. Each event is
sent after the status patch it reports has succeeded. Delivery is at most once: a failed POST is
retried with the sink backoff and then dropped, and a controller crash between the patch and the
POST loses that event rather than repeating it. `status.output` stays the record of the result.
There are no init-phase events, since no init container runs.


An errored, expired or cancelled batch request moves the Agent to `Failed`, with the provider's
message in `status.failureReason`.

## Timeouts and fallback

`batch.timeoutMinutes` (default `1440`, 24 hours) counts from the Agent's `startedAt`, the moment the
batch was submitted. When it passes, the controller cancels the batch and applies `batch.onTimeout`:

- **`fail`** (the default): the Agent becomes `Failed` with reason `batch timed out`. Nothing more is
  spent.
- **`fallback`**: the controller sets `status.batchFallback: true`, keeps `batchId` for the audit trail,
  and starts an ordinary Job for the same Agent, built from the Station exactly like an interactive run.
  The answer arrives sooner but costs the full API price, and the fallback is allowed for every model
  that batch accepts. From then on the Agent is a normal Job run: the Station's `deadlineMinutes`
  applies to the Job, counted from when it is created.

The fallback Job counts toward the Station's `maxConcurrentRuns`. If the Station is full, the Agent
stays `Running` with `batchFallback: true` until a slot frees. If the batch result arrives in the same
reconcile as the timeout, the result wins and no fallback starts.

## Concurrency and polling

An in-flight batch is a `Running` run, so `maxConcurrentRuns` and `concurrencyPolicy` limit batch
Agents the same way they limit Jobs. Under `Replace`, a new batch Agent at a full Station deletes the
oldest `Running` run and submits its batch. See [Station](../reference/crd-station.md#batch-runs).

The controller polls each in-flight batch at most once every `BATCH_POLL_SECONDS` seconds (default
`60`), not on every watch event. Set it as an environment variable on the controller Deployment.

## Cancelling and cleanup

Delete the Agent to cancel its batch:

```sh
kubectl -n ai-agents delete agent ticket-summary-abc12
```

On submit the controller adds the finalizer `agents.re-cinq.com/batch-cleanup` to the Agent. While it
is present, a delete makes the controller cancel the batch if it is still running, delete the batch at
the provider (Anthropic otherwise keeps results for 29 days), and then remove the finalizer so the
Agent goes away. The same cleanup runs after every finished or timed-out batch, so history pruning
removes finished batch Agents straight away.

If the provider cleanup keeps failing, the controller retries and counts the failures in
`status.batchCleanupAttempts`, and the controller's `/metrics` counts each failed attempt in
`controller_batch_cleanup_failures_total`. After 5 failures it removes the finalizer anyway and leaves the
provider object behind, so a delete is never stuck. A failed cleanup never changes the Agent's phase.

## Security and network

Batch runs change who sees the provider key. With the `components/batch` component the controller
gets `get` on the `agent-secrets` Secret, and the controller pod calls `https://api.anthropic.com`
itself. The shipped NetworkPolicy
selects run pods only, so the controller's egress is open unless your cluster restricts it; if it
does, allow HTTPS to `api.anthropic.com`. See [RBAC & network](../reference/rbac-and-network.md).
