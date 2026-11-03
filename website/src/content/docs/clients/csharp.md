---
title: C# client
description: Launch and watch Agents from .NET with the official KubernetesClient package.
---

`ReCinq.AgentContracts` gives a .NET program the types of every resource and a small client that
creates runs, waits for them and applies recipes. It is built on the official `KubernetesClient`
package. The types are generated from the same source as the CRDs, so they always match the cluster
you install from the same release. It targets .NET 8 and later.

## Install

The package is published to GitHub Packages on every release. GitHub Packages asks for a token
even for public packages, so add the feed once with a personal access token that has
`read:packages`:

```sh
dotnet nuget add source https://nuget.pkg.github.com/re-cinq/index.json \
  --name re-cinq --username YOUR_GITHUB_USER --password YOUR_TOKEN --store-password-in-clear-text

dotnet add package ReCinq.AgentContracts --version 0.15.0
```

## Create the client

```csharp
using k8s;
using ReCinq.AgentContracts;

var kube = new Kubernetes(KubernetesClientConfiguration.BuildDefaultConfig()); // kubeconfig or in-cluster

var agents = new AgentContractsClient(kube); // namespace defaults to "ai-agents"
```

### In ASP.NET Core

Register both as singletons:

```csharp
builder.Services.AddSingleton<IKubernetes>(_ =>
    new Kubernetes(KubernetesClientConfiguration.BuildDefaultConfig()));

builder.Services.AddSingleton(services =>
    new AgentContractsClient(services.GetRequiredService<IKubernetes>(), builder.Configuration["Agents:Namespace"]));
```

## Launch a run and wait for it

```csharp
var run = await agents.CreateAgentAsync(new Agent
{
    Metadata = new V1ObjectMeta { GenerateName = "fix-bug-" },
    Spec = new AgentSpec
    {
        StationRef = "bug-fixer",
        TargetRepo = "re-cinq/ai-agent-subsystem",
        Parameters = new() { ["issue"] = "123" },
    },
});

using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(30));

var finished = await agents.WaitForAgentAsync(run.Metadata.Name, TimeSpan.FromSeconds(5), timeout.Token);

Console.WriteLine($"{finished.Status?.Phase} {finished.Status?.PrUrl}");
```

`WaitForAgentAsync` polls until the phase is `Succeeded` or `Failed`. It throws
`OperationCanceledException` when the token is cancelled first, so the token's timeout is the wait's
timeout.

## Apply a recipe and a runtime

```csharp
var definition = new AgentDefinition
{
    Metadata = new V1ObjectMeta { Name = "bug-fixer" },
    Spec = new AgentDefinitionSpec { Model = "claude-sonnet-5-5", Prompt = "Fix the bug described in issue {issue}." },
};

await agents.ApplyAgentDefinitionAsync(definition);
```

`ApplyAgentDefinitionAsync` and `ApplyStationAsync` are server-side apply with the field manager
`agent-contracts` and forced ownership. A resource without a name throws `ArgumentException` with
`apply <Kind>: metadata.name is required` before any request is sent.

## Methods

| Call | Does |
| --- | --- |
| `CreateAgentAsync(agent)` | Start one run in the client's namespace. |
| `GetAgentAsync(name)` | Read one run; an unknown name throws `HttpOperationException` with a 404. |
| `FindAgentsAsync(labelSelector)` | List runs matching a selector such as `team=web`. |
| `GetModelCatalogAsync()` | Read the models the subsystem can run. |
| `ApplyAgentDefinitionAsync`, `ApplyStationAsync` | Server-side apply a recipe or runtime. |
| `AgentContractsClient.IsTerminal(agent)` | Whether a run has finished. |
| `WaitForAgentAsync(name, interval, token)` | Poll until the run finishes or the token is cancelled. |

## Permissions

The [`agent-launcher` role](../reference/rbac-and-network.md#caller-role) covers creating, reading
and listing Agents and reading the ModelCatalog. Applying AgentDefinitions and Stations needs
`get`, `create` and `patch` on `agentdefinitions` and `stations`, which that role does not grant;
bind a separate role for the app that manages recipes.

## Types

Every kind implements `IKubernetesObject<V1ObjectMeta>` and carries `[KubernetesEntity]` with its
group, version and plural, plus a `<Kind>List`. You can also call `KubernetesClient` directly, for
example `kube.CustomObjects.ListNamespacedCustomObjectAsync<AgentList>(...)`.

Required fields are `required` properties. Optional ones are nullable and left out of the JSON when
`null`, so the API server applies the CRD's default. Free-form fields such as `StationSpec.Template`
are `JsonNode`. Enums write their wire value, for example `SelectEvent.ToolCall` is `"tool_call"`,
and a value the package does not know reads as the first member, the same rule the controller
applies.

## Test without a cluster

`Kubernetes` accepts `DelegatingHandler`s, so a handler that answers from memory and never calls
the network runs the client in a unit test:

```csharp
sealed class FakeApi : DelegatingHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) =>
        Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            RequestMessage = request, // the client reads it back
            Content = new StringContent("{}", Encoding.UTF8, "application/json"),
        });
}

var kube = new Kubernetes(new KubernetesClientConfiguration { Host = "http://fake-api" }, new FakeApi());
```
