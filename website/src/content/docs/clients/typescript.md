---
title: TypeScript client
description: Launch and watch Agents from Node.js or a browser UI with @re-cinq/agent-contracts.
---

`@re-cinq/agent-contracts` gives a TypeScript program the types of every resource and a small
client that creates runs, waits for them and applies recipes. The types are generated from the
same source as the CRDs, so they always match the cluster you install from the same release.

## Install

```sh
npm install @re-cinq/agent-contracts
```

Use the package version that matches the subsystem release you run.

## Bring a transport

The client does not pick an HTTP library for you. It sends every call through a `KubeTransport`:
one `request` method that takes a method, path, query, body and content type, and returns a status
and a parsed body. This keeps the package free of dependencies and lets you reuse whatever
authentication your app already has.

A `fetch` transport with a bearer token:

```ts
import type { KubeTransport } from "@re-cinq/agent-contracts";

const transport: KubeTransport = {
  async request({ method, path, query, body, contentType }) {
    const url = new URL(path, process.env.KUBE_API_URL);
    for (const [key, value] of Object.entries(query ?? {})) {
      url.searchParams.set(key, value);
    }

    const response = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${process.env.KUBE_TOKEN}`,
        ...(body ? { "Content-Type": contentType ?? "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });

    return { status: response.status, body: await response.json() };
  },
};
```

Inside a pod, read the token from `/var/run/secrets/kubernetes.io/serviceaccount/token` and use
`https://kubernetes.default.svc` as the URL. A transport built on `@kubernetes/client-node` works the
same way. Any status outside 2xx makes the client throw `kube request failed (<status>)`.

## Launch a run and wait for it

```ts
import { AgentContractsClient, waitForAgent } from "@re-cinq/agent-contracts";

const client = new AgentContractsClient(transport); // namespace defaults to "ai-agents"

const run = await client.createAgent({
  metadata: { generateName: "fix-bug-" },
  spec: {
    stationRef: "bug-fixer",
    targetRepo: "re-cinq/ai-agent-subsystem",
    parameters: { issue: "123" },
  },
});

const finished = await waitForAgent(client, run.metadata!.name!, { intervalMs: 5000, attempts: 360 });

console.log(finished.status?.phase, finished.status?.prUrl);
```

`waitForAgent` polls `getAgent` until the phase is `Succeeded` or `Failed`. It throws once the
attempts run out (600 attempts every 2 seconds by default). Pass your own `sleep` to drive it from a
test clock.

## Apply a recipe and a runtime

```ts
await client.applyAgentDefinition({
  metadata: { name: "bug-fixer" },
  spec: { model: "claude-sonnet-5-5", prompt: "Fix the bug described in issue {issue}." },
});

await client.applyStation({ metadata: { name: "bug-fixer" }, spec: { agentDefRef: "bug-fixer" } });
```

Both calls are server-side apply with the field manager `agent-contracts` and forced ownership, so
pushing edited YAML from a UI overwrites fields other managers set. A resource without
`metadata.name` is rejected before any request is sent.

## Methods

| Call | Does |
| --- | --- |
| `createAgent(agent)` | Start one run in the client's namespace. |
| `getAgent(name)` | Read one run. |
| `findAgents(labelSelector)` | List runs matching a selector such as `team=web`. |
| `getModelCatalog()` | Read the models the subsystem can run. |
| `applyAgentDefinition(def)`, `applyStation(station)` | Server-side apply a recipe or runtime. |
| `isTerminal(agent)` | Whether a run has finished. |
| `waitForAgent(client, name, options)` | Poll until the run finishes. |

## Permissions

The [`agent-launcher` role](../reference/rbac-and-network.md#caller-role) covers creating, reading
and listing Agents and reading the ModelCatalog. Applying AgentDefinitions and Stations needs
`get`, `create` and `patch` on `agentdefinitions` and `stations`, which that role does not grant;
bind a separate role for the app that manages recipes.

## Types only

To type manifests without calling the cluster, import only the types:

```ts
import type { AgentDefinition, Phase } from "@re-cinq/agent-contracts";
```

Optional fields are optional properties. Free-form fields such as `StationSpec.template` are
`unknown`. Enums are string unions, such as `Phase`.
