---
title: ModelCatalog CRD
description: Field reference for the ModelCatalog custom resource, the list of models the subsystem can run.
---

**Group/Version:** `agents.re-cinq.com/v1alpha1` · **Kind:** `ModelCatalog` · **Scope:** Namespaced ·
**Short name:** `mc`

The models the subsystem can run with the API keys it has. There is one object, named `default`, in
the controller's namespace (`ai-agents` by default). It has no `spec`: the controller owns it and
writes only `status`. Callers such as an orchestrator read it to find out which model ids they can
put in an AgentDefinition.

```sh
kubectl get mc default -n ai-agents -o yaml
```

`kubectl get mc` prints the `Refreshed` and `Age` columns.

## `status`

| Field | Type | Notes |
| --- | --- | --- |
| `refreshedAt` | date-time | When the controller last refreshed the catalog (RFC 3339). |
| `vendors` | [] object | One entry per vendor that has at least one key to query; see below. |

### `status.vendors[]`

| Field | Type | Notes |
| --- | --- | --- |
| `vendor` | string | `claude`, `codex` or `gemini`: the agent CLI the subsystem routes these model ids to. |
| `provider` | string | `anthropic`, `openai` or `gemini`: the API the models were listed from. |
| `secretRefs` | []string | The `agent-secrets` keys that were queried. An AgentDefinition can run these models when its `resources.secrets` maps one of these keys. |
| `error` | string | Why some keys failed on the last refresh, as `<ref>: <message>; ...`. Empty when every key answered. |
| `models` | [] object | `{id, displayName}` for each model, deduplicated by `id` and sorted by `id`. |

## How the catalog is filled

The controller lists the AgentDefinitions in its namespace and collects every distinct
`agent-secrets` key they map in `resources.secrets` under one of these env names:

| `resources.secrets` name | `vendor` | `provider` | List call |
| --- | --- | --- | --- |
| `ANTHROPIC_API_KEY` | `claude` | `anthropic` | `GET /v1/models` (paginated) |
| `OPENAI_API_KEY` | `codex` | `openai` | `GET /v1/models` |
| `GEMINI_API_KEY` | `gemini` | `gemini` | `GET /v1beta/models` (paginated), only models that support `generateContent` |

It reads each key from the `agent-secrets` Secret and calls the vendor's list-models API with it.
Only model ids the subsystem would route back to that vendor are kept, so OpenAI's embeddings,
`dall-e` and `whisper` models and Gemini's `gemma` models are dropped. Models from several keys of
the same vendor are merged into one entry.

A key that fails sets that vendor's `error`; the other keys and vendors still publish their models.
If every key of a vendor fails, its entry has the `error` and no `models`.

Only the leader replica refreshes the catalog: once right after it becomes leader, then every
`MODEL_CATALOG_REFRESH_SECONDS` seconds (default `3600`), set as an environment variable on the
controller Deployment. A key mapped by a new AgentDefinition shows up at the next refresh. A refresh
that fails as a whole (for example the AgentDefinition list is denied) is retried after 30 seconds.

The `opencode` and `exec` models are not listed.

## Enable the catalog

The catalog is off by default. Without the `deploy/components/model-catalog` kustomize component
the controller does nothing for it and no `default` object is written. The component grants the
controller `get` on the `agent-secrets` Secret (that Secret only) and sets
`MODEL_CATALOG_ENABLED=true` on the controller Deployment. Add it next to the base install as shown
in [Install](../setup/install.md#enable-the-model-catalog-optional); it can be combined with the
batch component. See [RBAC & network](./rbac-and-network.md#model-catalog-component-opt-in) for the
grant and the egress the controller then needs.

`MODEL_CATALOG_ENABLED` accepts only `true` or `false`, and `MODEL_CATALOG_REFRESH_SECONDS` only a
non-negative integer. Any other value stops the controller at startup with
`MODEL_CATALOG_ENABLED must be "true" or "false", got: "<value>"` or
`MODEL_CATALOG_REFRESH_SECONDS must be a non-negative integer, got: "<value>"`.

## Reading it from TypeScript

`@re-cinq/agent-contracts` exports the `ModelCatalog`, `ModelCatalogStatus`, `VendorModels` and
`ModelInfo` types, and `AgentContractsClient` has a `getModelCatalog()` method that returns the
`default` object in the client's namespace. It throws on a 404, which is what you get when the
catalog is not enabled:

```ts
const client = new AgentContractsClient(transport, "ai-agents");
const catalog = await client.getModelCatalog();
const claudeModelIds = catalog.status?.vendors
  ?.find((vendorModels) => vendorModels.vendor === "claude")
  ?.models?.map((model) => model.id);
```

The caller role in `deploy/rbac/caller-rbac.yaml` grants `get`, `list` and `watch` on
`modelcatalogs`.

## Limits

AgentDefinition models are not checked against the catalog. A model id that is not in it still
runs, and an unknown id runs on the Claude CLI.
