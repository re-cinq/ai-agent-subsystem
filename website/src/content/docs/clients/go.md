---
title: Go client
description: Launch and watch Agents from Go with controller-runtime and agent-contracts-go.
---

`agent-contracts-go` gives a Go program the types of every resource as real Kubernetes objects and
a small client that creates runs, waits for them and applies recipes. The types are generated from
the same source as the CRDs, so they always match the cluster you install from the same release.

## Install

```sh
go get github.com/re-cinq/ai-agent-subsystem/packages/agent-contracts-go@v0.15.0
```

The module is tagged `packages/agent-contracts-go/vX.Y.Z` from the same commit as each release, so
pick the version you run. It depends on `controller-runtime` and `apimachinery`.

## Register the types

Every kind embeds `metav1.TypeMeta` and `metav1.ObjectMeta`, has a `*List` type and DeepCopy
methods, so it registers with any client-go or controller-runtime scheme:

```go
import (
	agentcontracts "github.com/re-cinq/ai-agent-subsystem/packages/agent-contracts-go"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/config"
)

scheme := runtime.NewScheme()
if err := agentcontracts.AddToScheme(scheme); err != nil {
	return err
}

kube, err := client.New(config.GetConfigOrDie(), client.Options{Scheme: scheme})
if err != nil {
	return err
}

agents := agentcontracts.NewClient(kube, "") // "" means the ai-agents namespace
```

In an operator built with controller-runtime, add `agentcontracts.AddToScheme` to the manager's
scheme and pass `manager.GetClient()` to `NewClient`. You can also watch the kinds directly, for
example `Owns(&agentcontracts.Agent{})`.

## Launch a run and wait for it

```go
run := &agentcontracts.Agent{
	ObjectMeta: metav1.ObjectMeta{GenerateName: "fix-bug-"},
	Spec: agentcontracts.AgentSpec{
		StationRef: "bug-fixer",
		TargetRepo: "re-cinq/ai-agent-subsystem",
		Parameters: map[string]string{"issue": "123"},
	},
}

if err := agents.CreateAgent(ctx, run); err != nil {
	return err
}

ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
defer cancel()

finished, err := agents.WaitForAgent(ctx, run.Name, 5*time.Second)
if err != nil {
	return err
}

fmt.Println(finished.Status.Phase, finished.Status.PrURL)
```

`WaitForAgent` polls until the phase is `Succeeded` or `Failed`. It returns an error when the
context ends first, so the context's deadline is the timeout.

## Apply a recipe and a runtime

```go
definition := &agentcontracts.AgentDefinition{
	ObjectMeta: metav1.ObjectMeta{Name: "bug-fixer"},
	Spec: agentcontracts.AgentDefinitionSpec{
		Model:  "claude-sonnet-5-5",
		Prompt: "Fix the bug described in issue {issue}.",
	},
}

if err := agents.ApplyAgentDefinition(ctx, definition); err != nil {
	return err
}
```

`ApplyAgentDefinition` and `ApplyStation` are server-side apply with the field manager
`agent-contracts` and forced ownership. A resource without a name fails with
`apply <Kind>: metadata.name is required` before any request is sent.

## Methods

| Call | Does |
| --- | --- |
| `CreateAgent(ctx, agent)` | Start one run in the client's namespace. |
| `GetAgent(ctx, name)` | Read one run. |
| `FindAgents(ctx, labelSelector)` | List runs matching a selector such as `team=web`; an invalid selector is an error. |
| `GetModelCatalog(ctx)` | Read the models the subsystem can run. |
| `ApplyAgentDefinition`, `ApplyStation` | Server-side apply a recipe or runtime. |
| `IsTerminal(agent)` | Whether a run has finished. |
| `WaitForAgent(ctx, name, interval)` | Poll until the run finishes or the context ends. |

## Permissions

The [`agent-launcher` role](../reference/rbac-and-network.md#caller-role) covers creating, reading
and listing Agents and reading the ModelCatalog. Applying AgentDefinitions and Stations needs
`get`, `create` and `patch` on `agentdefinitions` and `stations`, which that role does not grant;
bind a separate role for the app that manages recipes.

## Types

Fields the CRD schema defaults, such as `StationSpec.DeadlineMinutes`, are pointers: leave them
`nil` and the API server applies the default. Free-form fields such as `StationSpec.Template` are
`runtime.RawExtension`. Enums are string types with one constant per value, such as
`agentcontracts.PhaseSucceeded`.

## Test without a cluster

The kinds work with controller-runtime's fake client:

```go
kube := fake.NewClientBuilder().WithScheme(scheme).WithObjects(existingAgent).Build()
agents := agentcontracts.NewClient(kube, "")
```
