---
title: Batch runs
description: Run a single-call recipe through the provider's batch API for about half the price.
---

Provider batch APIs cost about 50% less than the regular API, but a result can take up to 24 hours
and each request is one model call with no tool loop. An AgentDefinition with `execution: batch`
uses this path. No Job or pod is created: the controller submits the prompt, polls the batch from
its reconcile loop, and records the result on the Agent.

Batch runs support Anthropic (Claude models), Gemini (Gemini models, see [Gemini](#gemini)) and
OpenAI (Codex-routed models, see [OpenAI](#openai)).

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
  - https://github.com/re-cinq/ai-agent-subsystem//deploy?ref=v0.15.0
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/batch?ref=v0.15.0
```

From a checkout, use the local paths instead (`resources: [deploy]`, `components:
[deploy/components/batch]`). Apply it with `kubectl apply -k .`. The release `install.yaml` does
not include the component.

The controller parses its batch settings strictly. `BATCH_ENABLED` accepts only `true` or `false`,
and `BATCH_POLL_SECONDS` (see [Concurrency and polling](#concurrency-and-polling)) only a
non-negative integer. Any other value stops the controller at startup with
`BATCH_ENABLED must be "true" or "false", got: "<value>"` or
`BATCH_POLL_SECONDS must be a non-negative integer, got: "<value>"`.

## When to use it

Use batch for work that fits in one prompt and one answer and can wait: classifying or summarising
documents, drafting text from parameters, reviewing a diff passed in the prompt. Keep interactive
execution for anything that needs tools, a checked-out repository, several turns or a fast answer.

A batch definition may not set any field that needs the CLI harness. The Agent fails with
`batch execution does not support <field>` when the definition sets:

- `allowed_tools`, `disallowed_tools` or `max_turns`
- `resources.repos`, `resources.mcp_servers`, `resources.skills` or `resources.conversation`
- `output.watch`
- the `exec` model, or an opencode model

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
apiVersion: agents.re-cinq.com/v1beta1
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
apiVersion: agents.re-cinq.com/v1beta1
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
apiVersion: agents.re-cinq.com/v1beta1
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
uses `claude-opus-5-5`: unlike the CLI, a batch request has no default model of its own. That
default only covers an empty model, which routes to Claude; a Gemini or OpenAI definition always
names its model.

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
model that is not in it, such as a dated snapshot id, reports `0`. `claude-haiku-5-5` has a
long-prompt tier: a request with more than 100,000 input tokens is billed at that tier's higher
rate for all of its input and output tokens.

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
2. When the batch ends, each CLI line that passes `output.select`, then
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
The sinks get every CLI line of the result, while `status.output` is capped at `MAX_OUTPUT_BYTES`,
so for a long answer a sink sees lines that `status.output` no longer holds.
There are no init-phase events, since no init container runs.


An errored, expired or canceled batch request moves the Agent to `Failed`. For an errored request
`status.failureReason` is the provider's error as `<type>: <message>`; an expired or canceled one
gives `batch request expired` or `batch request canceled`.

## Gemini

A definition whose model routes to Gemini (any model id containing `gemini`, such as
`gemini-3.1-flash-lite`) is submitted to the
[Gemini Batch API](https://ai.google.dev/gemini-api/docs/batch-mode) instead, with
`status.batchProvider: gemini`. Everything above about validation, timeouts, fallback, concurrency,
sinks and cleanup applies unchanged. The key comes from the `resources.secrets` entry named
`GEMINI_API_KEY`, the same entry a gemini CLI run uses:

```sh
kubectl -n ai-agents create secret generic agent-secrets \
  --from-literal=gemini-key="$GEMINI_API_KEY"
```

```yaml
apiVersion: agents.re-cinq.com/v1beta1
kind: AgentDefinition
metadata:
  name: ticket-triage
  namespace: ai-agents
spec:
  description: Classify a support ticket.
  model: gemini-3.1-flash-lite
  execution: batch
  prompt: |
    Classify this support ticket by severity and component:
    {ticket}
  output:
    schema:
      type: object
      properties:
        severity: {type: string, enum: [low, medium, high]}
        component: {type: string}
      required: [severity, component]
  resources:
    secrets:
      - name: GEMINI_API_KEY
        ref: gemini-key
```

The controller sends one inline request through `models/<model>:batchGenerateContent`. The batch's
`display_name` and the request's `metadata.key` are the Agent's uid, and `batch.maxTokens` sets
`generationConfig.maxOutputTokens`. An `output.schema` becomes structured output:
`generationConfig.responseMimeType: application/json` with the schema as
`responseJsonSchema`, so the model's answer is JSON that matches it. `status.batchId` is the batch's
id, the part of its `batches/<id>` name after the slash.

When the batch ends, `status.output` and the sinks get the lines the gemini CLI prints with
`--output-format stream-json` for a single-turn, no-tool run:

```json
{"type":"init","session_id":"<agent uid>","model":"gemini-3.1-flash-lite"}
{"type":"message","role":"assistant","content":"{\"severity\":\"high\",\"component\":\"login\"}","delta":true}
{"type":"result","status":"success","stats":{"total_tokens":61,"input_tokens":48,"output_tokens":13,"cached":0,"input":48,"duration_ms":0,"tool_calls":0,"models":{"gemini-3.1-flash-lite":{"total_tokens":61,"input_tokens":48,"output_tokens":13,"cached":0,"input":48}}}}
```

The assistant `message` carries the first candidate's text, with thought parts left out as the CLI
leaves them out. `stats` comes from the response's `usageMetadata`: `input_tokens` is the prompt
token count, `cached` the cached content tokens, `input` the prompt tokens that were not cached,
`output_tokens` the candidate tokens, and `total_tokens` the total, which includes thinking tokens.
`models` is keyed by the response's `modelVersion`. The batch reports no timing, so `duration_ms` is
`0`. The gemini CLI reports no cost, so neither does a Gemini batch run. Unlike a CLI run, there is
no `timestamp` on the lines and no `message` echoing the user prompt; neither is part of the
[consumer contract](../reference/notification-api.md#consumer-contract).

A failed request, a response with no candidates (a blocked prompt fails with
`response blocked: <blockReason>`), or a batch that ends `FAILED`, `CANCELLED` or `EXPIRED` (`batch failed`, `batch cancelled` or
`batch expired`, followed by `: <message>` when the batch carries an error), gives
the `init` line and
a `result` with `status: "error"` and `error: {type: "BatchError", message}`, as the CLI reports an
API error, and the Agent goes `Failed` with that message as `status.failureReason`. The controller
deletes the batch once it is done, as for Anthropic (Google otherwise keeps batch results for
6 weeks).

## OpenAI

A definition whose model routes to Codex (`gpt-*`, `o1*`, `o3*`, `o4*` or any id containing `codex`,
such as `gpt-5-mini`) is submitted to the
[OpenAI Batch API](https://platform.openai.com/docs/guides/batch) instead, with
`status.batchProvider: openai`. Everything above about validation, timeouts, fallback, concurrency,
sinks and cleanup applies unchanged; a fallback Job runs the codex CLI. The key comes from the
`resources.secrets` entry named `OPENAI_API_KEY`:

```sh
kubectl -n ai-agents create secret generic agent-secrets \
  --from-literal=openai-key="$OPENAI_API_KEY"
```

```yaml
apiVersion: agents.re-cinq.com/v1beta1
kind: AgentDefinition
metadata:
  name: ticket-triage
  namespace: ai-agents
spec:
  description: Classify a support ticket.
  model: gpt-5-mini
  execution: batch
  prompt: |
    Classify this support ticket by severity and component:
    {ticket}
  output:
    schema:
      type: object
      properties:
        severity: {type: string, enum: [low, medium, high]}
        component: {type: string}
      required: [severity, component]
      additionalProperties: false
  resources:
    secrets:
      - name: OPENAI_API_KEY
        ref: openai-key
```

The OpenAI Batch API reads its requests from a file, so the controller first uploads a one-line
JSONL file (`POST /v1/files`, `purpose=batch`) holding a `POST /v1/responses` call, the Responses API
the codex CLI uses, and then creates a batch over it (`POST /v1/batches`, `completion_window: 24h`).
The line's `custom_id` is the Agent's uid, `input` is the rendered prompt and `batch.maxTokens` sets
`max_output_tokens`. An `output.schema` becomes `text.format` of type `json_schema` with
`strict: true`, so the answer is JSON that matches it. Strict mode needs every property listed in
`required` and `additionalProperties: false` on each object; a schema without them fails the request,
and the Agent with it. `status.batchId` is the batch's id (`batch_…`).

When the batch ends, the controller reads the line its output file (or, for a failed request, its
error file) holds, and `status.output` and the sinks get the lines `codex exec --json` prints for a
single-turn, no-tool run:

```json
{"type":"thread.started","thread_id":"<agent uid>"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"severity\":\"high\",\"component\":\"login\"}"}}
{"type":"turn.completed","usage":{"input_tokens":48,"cached_input_tokens":0,"output_tokens":75,"reasoning_output_tokens":64}}
```

The `agent_message` carries the text of the response's `message` items; reasoning items are left out,
as the CLI leaves them out of its message. `usage` comes from the response's `usage`:
`cached_input_tokens` is `input_tokens_details.cached_tokens` and `reasoning_output_tokens` is
`output_tokens_details.reasoning_tokens`. The codex CLI reports no cost, so neither does an OpenAI
batch run.

A failed request, a response cut off as `incomplete` (`Incomplete response returned, reason:
max_output_tokens`, as the CLI words it), a response whose message holds only a `refusal` (the
refusal text is the error), a completed batch whose output and error files hold no line (`batch
completed without a result`), or a batch that ends `failed`, `expired` or `cancelled` (`batch failed`, `batch expired` or
`batch cancelled`, followed by `: <message>` with the batch's first error when it has one) gives `thread.started`, `turn.started`, an `error` line and a `turn.failed` with `error.message`, as the
CLI reports an API error, and the Agent goes `Failed` with that message as `status.failureReason`.

OpenAI batch objects cannot be deleted, so cleanup deletes the batch's input file and its output and
error files (`DELETE /v1/files/<id>`), which hold the prompt and the answer. A cancelled batch stays
`cancelling` for up to about 10 minutes and writes its output and error files only then, so cleanup
waits for the batch to reach `completed`, `failed`, `expired` or `cancelled` before deleting anything.
Every file is tried on each cleanup, and a file that is already gone (`404`) counts as deleted, so a
retry after a partial cleanup finishes the rest.

:::caution[The Floor does not read codex output yet]
The Floor parses no codex event today, for CLI runs and batch runs alike: a codex run's final text
and token usage do not reach it, only the lifecycle events. The
[consumer contract](../reference/notification-api.md#codex) pins the codex fields a parser would read.
:::

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
A poll that errors (the provider is unreachable, answers an HTTP error, or returns a body the
controller cannot read) is logged and retried on the next poll, so the Agent stays `Running` until
the batch finishes or `batch.timeoutMinutes` applies `onTimeout`.

## Cancelling and cleanup

Delete the Agent to cancel its batch:

```sh
kubectl -n ai-agents delete agent ticket-summary-abc12
```

On submit the controller adds the finalizer `agents.re-cinq.com/batch-cleanup` to the Agent. While it
is present, a delete makes the controller cancel the batch if it is still running, delete the batch at
the provider (Anthropic otherwise keeps results for 29 days, Gemini for 6 weeks; for OpenAI the batch's
files), and then remove the finalizer so the
Agent goes away. The same cleanup runs after every finished or timed-out batch, so history pruning
removes finished batch Agents straight away.

A cancel does not end a batch at once: Anthropic keeps it `canceling` and only an ended batch can be
deleted, and OpenAI keeps it `cancelling` until it writes its result files. While the batch has not
settled, the controller keeps the finalizer and tries the cleanup again on later reconciles (the
safety-net poll runs every ~15 seconds), without counting those tries as failures. A delete of a
batch Agent can therefore take a few minutes. Gemini's cleanup sends the `DELETE` right after the
cancel, without waiting for the batch to settle. A batch still unsettled 48 hours after the Agent's
`startedAt` is treated as stuck, and its cleanups count as failures from then on.

If the provider cleanup keeps failing, the controller retries and counts the failures in
`status.batchCleanupAttempts`, and the controller's `/metrics` counts each failed attempt in
`controller_batch_cleanup_failures_total`. After 5 failures it removes the finalizer anyway and leaves the
provider object behind, so a delete is never stuck. A failed cleanup never changes the Agent's phase.

## Security and network

Batch runs change who sees the provider key. With the `components/batch` component the controller
gets `get` on the `agent-secrets` Secret, and the controller pod calls `https://api.anthropic.com`
(Claude models), `https://generativelanguage.googleapis.com` (Gemini models) and
`https://api.openai.com` (Codex-routed models) itself. The shipped NetworkPolicy selects run pods
only, so the controller's egress is open unless your cluster restricts it; if it does, allow HTTPS
to `api.anthropic.com`, `generativelanguage.googleapis.com` and `api.openai.com`. See [RBAC & network](../reference/rbac-and-network.md).
