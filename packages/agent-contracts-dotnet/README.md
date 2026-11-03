# ReCinq.AgentContracts (C#)

Types and a small client for the [ai-agent-subsystem](https://github.com/re-cinq/ai-agent-subsystem)
Custom Resources: **Agent**, **Station**, **AgentDefinition**, **ModelCatalog** and **AgentSpawner** (API group
`agents.re-cinq.com/v1beta1`), built on the official [`KubernetesClient`](https://www.nuget.org/packages/KubernetesClient) package.

The types are generated from the D structs that define the CRDs, the same source the CRD YAML and
the other contract packages come from, so they cannot drift. CI fails if the committed file stops
matching the model, and a test decodes every manifest in `examples/` with unknown fields rejected.

## Install

The package is published to GitHub Packages on every release. Add the feed once, with a GitHub
token that has `read:packages`:

```sh
dotnet nuget add source https://nuget.pkg.github.com/re-cinq/index.json \
  --name re-cinq --username YOUR_GITHUB_USER --password YOUR_TOKEN --store-password-in-clear-text
dotnet add package ReCinq.AgentContracts --version 0.15.0
```

Versions follow the subsystem's releases. It targets .NET 8 and later.

## Types

Every kind implements `IKubernetesObject<V1ObjectMeta>`, carries `[KubernetesEntity]` with its group,
version, kind and plural, and has a `<Kind>List`. Nested types are plain classes with
`System.Text.Json` attributes. Required fields are `required` properties; optional ones are nullable
and left out of the JSON when `null`, so the API server applies the CRD's default. Free-form fields
such as `StationSpec.Template` are `JsonNode`. Enums write their wire value (`SelectEvent.ToolCall`
is `"tool_call"`) and an unknown value reads as the first member, the same rule the controller applies.

## Client

```csharp
var kube = new Kubernetes(KubernetesClientConfiguration.BuildDefaultConfig());
var agents = new AgentContractsClient(kube, "ai-agents");

var run = await agents.CreateAgentAsync(new Agent
{
    Metadata = new V1ObjectMeta { GenerateName = "story-writer-run-" },
    Spec = new AgentSpec { StationRef = "story-writer", Parameters = new() { ["title"] = "The Last Lighthouse" } },
});

using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(30));
var finished = await agents.WaitForAgentAsync(run.Metadata.Name, TimeSpan.FromSeconds(5), timeout.Token);
```

| Method | Does |
| --- | --- |
| `CreateAgentAsync` | Start one run. |
| `GetAgentAsync`, `FindAgentsAsync` | Read one run, or list runs by label selector. |
| `WaitForAgentAsync` | Poll until the run is `Succeeded` or `Failed`, or the token is cancelled. |
| `GetModelCatalogAsync` | The models the subsystem can run with its configured keys. |
| `ApplyAgentDefinitionAsync`, `ApplyStationAsync` | Server-side apply a recipe or runtime (field manager `agent-contracts`, forced). |
| `AgentContractsClient.IsTerminal` | Whether a run has finished. |

## Development

`make regen` from the repository root rewrites `src/ReCinq.AgentContracts/Types.g.cs`; do not edit
it by hand. `make contracts-dotnet` builds and runs the tests with a 100% coverage gate on the client.
