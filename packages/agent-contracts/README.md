# @re-cinq/agent-contracts

TypeScript types and a thin, typed client for the [ai-agent-subsystem](https://github.com/re-cinq/ai-agent-subsystem) Custom Resources: **Agent**, **Station**, and **AgentDefinition** (API group `agents.re-cinq.com/v1alpha1`).

The types are generated directly from the D source structs that define the CRDs, so they cannot drift from the controller. A CI drift check fails the build if the committed output stops matching the model.

## Install

```sh
npm install @re-cinq/agent-contracts
```

## What you get

- **Types** for every resource and nested field: `Agent`, `Station`, `AgentDefinition`, their `*Spec`/`*Status` shapes, and the string-literal unions (`Phase`, `ConcurrencyPolicy`, `PermissionMode`, ...).
- **Constants**: `GROUP`, `VERSION`, `DEFAULT_NAMESPACE`.
- **`AgentContractsClient`** — create/read/list Agents and server-side-apply Stations and AgentDefinitions.
- **Helpers**: `isTerminal(agent)` and `waitForAgent(client, name, options?)`.

The client takes a `KubeTransport` you supply, so its logic stays decoupled from any particular HTTP stack and is deterministically testable with an in-memory fake — no cluster, no mocks.

## Types only

If you just need to type Kubernetes objects (e.g. to validate YAML or build a UI form), import the types and ignore the client:

```ts
import type { AgentDefinition, Station, Agent, Phase } from "@re-cinq/agent-contracts";

const recipe: AgentDefinition = {
  metadata: { name: "bug-fixer" },
  spec: {
    model: "claude-sonnet-4-6",
    prompt: "Fix the bug described in issue {issue}.",
    allowed_tools: ["bash", "edit"],
  },
};
```

## Using the client

The client speaks to the Kubernetes API through a `KubeTransport` — one method that turns a `KubeRequest` into a `KubeResponse`. Here is a minimal `fetch`-based transport:

```ts
import { AgentContractsClient, type KubeTransport } from "@re-cinq/agent-contracts";

const transport: KubeTransport = {
  async request({ method, path, query, body, contentType }) {
    const url = new URL(path, "https://your-kube-apiserver");
    for (const [key, value] of Object.entries(query ?? {})) {
      url.searchParams.set(key, value);
    }
    const res = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${process.env.KUBE_TOKEN}`,
        ...(body ? { "Content-Type": contentType ?? "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json() };
  },
};
```

Then launch a run and wait for it to finish:

```ts
import { AgentContractsClient, waitForAgent } from "@re-cinq/agent-contracts";

const client = new AgentContractsClient(transport, "ai-agents");

const run = await client.createAgent({
  metadata: { generateName: "fix-bug-" },
  spec: {
    stationRef: "bug-fixer",
    targetRepo: "re-cinq/ai-agent-subsystem",
    parameters: { issue: "123" },
  },
});

const finished = await waitForAgent(client, run.metadata!.name!);
console.log(finished.status?.phase, finished.status?.prUrl);
```

### API surface

| Member | Purpose |
| --- | --- |
| `new AgentContractsClient(transport, namespace?)` | Bind a transport to a namespace (defaults to `ai-agents`). |
| `createAgent(agent)` | Create one Agent run. |
| `getAgent(name)` | Read one Agent by name. |
| `findAgents(labelSelector)` | List Agents matching a Kubernetes label selector. |
| `applyStation(station)` | Server-side apply a Station. |
| `applyAgentDefinition(def)` | Server-side apply an AgentDefinition. |
| `isTerminal(agent)` | `true` once `status.phase` is `Succeeded` or `Failed`. |
| `waitForAgent(client, name, options?)` | Poll `getAgent` until terminal; `options` are `attempts`, `intervalMs`, and an injectable `sleep`. |

A non-2xx response throws an `Error` with the status code and body.

## License

Apache-2.0
