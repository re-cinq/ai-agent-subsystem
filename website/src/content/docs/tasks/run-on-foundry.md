---
title: Run on Microsoft Foundry
description: Point Claude Code and Codex runs at Microsoft Foundry by adding entries to the agent-secrets Secret.
---

Claude Code and Codex runs can call models deployed in Microsoft Foundry. The switch is a set of
entries in the `agent-secrets` Secret of the `ai-agents` namespace. AgentDefinitions do not change.
There is no Helm value to set, no controller setting and no restart.

## Prepare Azure

1. In your Foundry resource, create one deployment per model your definitions use. Name each
   deployment exactly after the model id in the definition (for example `claude-sonnet-4-6`). The
   definition's `model` reaches the CLI unchanged, so a deployment with another name is not found.
2. Pin each deployment to a model version, so a change on the Azure side does not change what your
   runs call.
3. Copy the endpoint and a key of the resource. The endpoint for Claude Code ends in
   `.services.ai.azure.com/anthropic`. The endpoint for Codex ends in `.openai.azure.com/openai/v1`.

The vendors describe the Azure side in detail.

- [Claude Code on Microsoft Foundry](https://code.claude.com/docs/en/microsoft-foundry)
- [Codex with Azure OpenAI in Foundry](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/codex)

## Switch on

Patch the Secret. Replace the placeholders with your endpoints and keys.

```sh
kubectl -n ai-agents patch secret agent-secrets --type=merge -p '{
  "stringData": {
    "AGENT_PROVIDER":             "foundry",
    "ANTHROPIC_FOUNDRY_BASE_URL": "https://my-foundry.services.ai.azure.com/anthropic",
    "ANTHROPIC_FOUNDRY_API_KEY":  "<foundry key>",
    "AZURE_OPENAI_BASE_URL":      "https://my-foundry.openai.azure.com/openai/v1",
    "AZURE_OPENAI_API_KEY":       "<azure openai key>"
  }
}'
```

`AGENT_PROVIDER: foundry` switches both harnesses. A cluster that runs only one of them adds only
that harness's address and key.

| Entry | Needed for | Value |
| --- | --- | --- |
| `AGENT_PROVIDER` | both | `foundry`, the only value supported |
| `ANTHROPIC_FOUNDRY_BASE_URL` | Claude Code | Foundry endpoint for Claude |
| `ANTHROPIC_FOUNDRY_API_KEY` | Claude Code | key of the Foundry resource |
| `AZURE_OPENAI_BASE_URL` | Codex | Azure OpenAI endpoint, ending in `/openai/v1` |
| `AZURE_OPENAI_API_KEY` | Codex | key of the Azure OpenAI resource |

The Secret of a Foundry-only cluster looks like this. It is also in
[`examples/foundry/agent-secrets.yaml`](https://github.com/re-cinq/ai-agent-subsystem/blob/main/examples/foundry/agent-secrets.yaml)
with placeholder values. Never commit real keys.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: agent-secrets
  namespace: ai-agents
type: Opaque
stringData:
  # The switch. Remove this entry and runs use the vendors' own APIs again.
  AGENT_PROVIDER: foundry

  # Claude Code
  ANTHROPIC_FOUNDRY_BASE_URL: https://my-foundry.services.ai.azure.com/anthropic
  ANTHROPIC_FOUNDRY_API_KEY: 3xAmPlEfOuNdRyKeY0000000000000000

  # Codex (the URL must end in /openai/v1)
  AZURE_OPENAI_BASE_URL: https://my-foundry.openai.azure.com/openai/v1
  AZURE_OPENAI_API_KEY: 3xAmPlEaZuReOpEnAiKeY00000000000

  # No Anthropic or OpenAI key is needed. Other entries stay as they are, for example:
  # GITHUB_TOKEN: ghp_...
```

On a Foundry-only cluster, remove `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` from the Secret. Then
no run can fall back to a leftover vendor key.

## Keep it across upgrades

The chart in this repository never creates or changes `agent-secrets`, so upgrades and controller
restarts leave your entries alone. Whether a patch stays depends on how the Secret came to exist.

If you made the Secret by hand with `kubectl create secret`, a patch stays until you change it.

If another tool generates the Secret, the tool overwrites a patch at its next sync. External
Secrets, Sealed Secrets and a manifest synced by Argo CD all work this way. Add the entries at that
source.

To see whether something manages the Secret, print its owner references, annotations and labels.

```sh
kubectl -n ai-agents get secret agent-secrets -o jsonpath='{.metadata.ownerReferences}{"\n"}{.metadata.annotations}{"\n"}{.metadata.labels}'
```

Owner references, or annotations and labels that name one of those tools, mean it is managed.

## Check it

Launch a run of an existing definition that uses a Claude or Codex model, for example the
[story-writer example](https://github.com/re-cinq/ai-agent-subsystem/tree/main/examples).

```sh
examples/run-agent.sh story-writer title="The Last Lighthouse"
kubectl -n ai-agents get agents -w
```

When the run ends, read the run pod's log.

```sh
kubectl -n ai-agents logs job/agent-job-<agent-name>
```

The run reaches `Succeeded`, or it fails with a message from the model endpoint. An authentication
or not-found error that names your Azure endpoint shows the run reached Foundry. An error that
names `api.anthropic.com` or `api.openai.com` shows it did not.

A run whose supervisor refuses the provider ends `Failed` and emits an `agent`/`failed` event with
reason `provider`. See [Troubleshooting](#troubleshooting).

Test with real Azure resources before you switch a cluster that others depend on.

## Switch off

Remove `AGENT_PROVIDER`. Runs use the vendors' own APIs again, so the vendor keys must be in the
Secret.

```sh
kubectl -n ai-agents patch secret agent-secrets --type=merge -p '{"data":{"AGENT_PROVIDER":null}}'
```

The patch names `data`. Kubernetes uses `stringData` only as an input for writing values, so a
`null` there removes nothing.

## What the system does with the entries

The controller cannot read `agent-secrets`, so it decides nothing. It adds each entry to Claude
Code and Codex run pods as an optional secret reference. Kubernetes sets the variable only if the
entry exists. The pod then acts on `AGENT_PROVIDER`.

| | Claude Code | Codex |
| --- | --- | --- |
| Entries offered | `AGENT_PROVIDER`, `ANTHROPIC_FOUNDRY_BASE_URL`, `ANTHROPIC_FOUNDRY_API_KEY` | `AGENT_PROVIDER`, `AZURE_OPENAI_BASE_URL`, `AZURE_OPENAI_API_KEY` |
| What `foundry` does | The supervisor sets `CLAUDE_CODE_USE_FOUNDRY=1` before it starts the CLI. | The init container writes a provider block into `~/.codex/config.toml`. |

For Codex the init container writes this block, in the run pod's `~/.codex/config.toml`. The line
`model_provider = "foundry"` goes first, then any content the file already had, then the table.

```toml
model_provider = "foundry"

[model_providers.foundry]
name = "Azure OpenAI"
base_url = "https://my-foundry.openai.azure.com/openai/v1"
env_key = "AZURE_OPENAI_API_KEY"
wire_api = "responses"
```

The key is never written to the file. `env_key` only names the variable Codex reads it from. If the
file already holds `[model_providers.foundry]`, the init step leaves it alone.

The vendor key (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` and its `CODEX_API_KEY` copy) is an optional
reference in the pod. A missing one no longer blocks the pod from starting. The run starts, and the
CLI reports the authentication error.

`AGENT_PROVIDER` is controller-owned. An entry of that name in a definition's `resources.env` or
`resources.secrets` is ignored, so a recipe cannot switch providers.

## Limits

- API keys only. Entra ID is not supported.
- [Batch runs](./batch-runs.md) and the [ModelCatalog](../reference/crd-modelcatalog.md) still call
  the vendor APIs.
- Gemini and OpenCode runs are unaffected.
- One provider per cluster. You cannot choose per Station or per definition.
- Foundry is the only provider. LiteLLM, Bedrock and Vertex are not supported.
- The deployment name must equal the model id. There is no mapping between them.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Run `Failed`, `agent`/`failed` event with reason `provider`, log line `unsupported AGENT_PROVIDER '<value>' (supported: foundry)` | `AGENT_PROVIDER` holds another value. Set it to `foundry` or remove it. Codex reports the same message from its init container. |
| Codex init fails with `AGENT_PROVIDER=foundry needs AZURE_OPENAI_BASE_URL in agent-secrets` | The Secret has no `AZURE_OPENAI_BASE_URL`. Add it. |
| 401 or 403 from the endpoint | The key is wrong, belongs to another resource, or is missing. Check `ANTHROPIC_FOUNDRY_API_KEY` or `AZURE_OPENAI_API_KEY`. |
| Authentication error naming a vendor key | The run did not use Foundry. Check that the `AGENT_PROVIDER` entry exists and, for a managed Secret, that it was added at the source. |
| 404 or a DNS error | The URL is wrong, the Codex URL lacks `/openai/v1`, or no deployment is named after the model id the definition uses. |

Secret changes reach new runs only. A run that already started keeps the values it started with.
