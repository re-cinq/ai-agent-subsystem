# agent-contracts-go

Go types and a small client for the [ai-agent-subsystem](https://github.com/re-cinq/ai-agent-subsystem)
Custom Resources: **Agent**, **Station**, **AgentDefinition** and **ModelCatalog** (API group
`agents.re-cinq.com/v1beta1`).

The types are generated from the D structs that define the CRDs, the same source the CRD YAML and
the TypeScript contracts come from, so they cannot drift. CI fails if the committed file stops
matching the model, and a test decodes every manifest in `examples/` with unknown fields
disallowed.

## Install

```sh
go get github.com/re-cinq/ai-agent-subsystem/packages/agent-contracts-go@latest
```

Versions follow the subsystem's releases: the module tag `packages/agent-contracts-go/v0.13.0` is
cut from the same commit as `v0.13.0`.

## Types

Every top-level kind embeds `metav1.TypeMeta` and `metav1.ObjectMeta`, has a `*List` type, and
implements `runtime.Object`, so it registers with any client-go or controller-runtime scheme:

```go
scheme := runtime.NewScheme()
_ = agentcontracts.AddToScheme(scheme)
```

Fields the CRD schema defaults (for example `StationSpec.DeadlineMinutes`) are pointers: leave them
`nil` and the API server applies the default. Free-form fields such as `StationSpec.Template` are
`runtime.RawExtension`.

## Client

`Client` wraps a controller-runtime client and works in one namespace (`ai-agents` by default):

```go
kube, _ := client.New(config.GetConfigOrDie(), client.Options{Scheme: scheme})
agents := agentcontracts.NewClient(kube, "")

run := &agentcontracts.Agent{
	ObjectMeta: metav1.ObjectMeta{GenerateName: "story-writer-run-"},
	Spec: agentcontracts.AgentSpec{
		StationRef: "story-writer",
		Parameters: map[string]string{"title": "The Last Lighthouse"},
	},
}
if err := agents.CreateAgent(ctx, run); err != nil {
	return err
}
finished, err := agents.WaitForAgent(ctx, run.Name, 2*time.Second)
```

| Method | Does |
| --- | --- |
| `CreateAgent` | Start one run. |
| `GetAgent`, `FindAgents` | Read one run, or list runs by label selector. |
| `WaitForAgent` | Poll until the run is `Succeeded` or `Failed`, or the context ends. |
| `GetModelCatalog` | The models the subsystem can run with its configured keys. |
| `ApplyAgentDefinition`, `ApplyStation` | Server-side apply a recipe or runtime. |
| `IsTerminal` | Whether a run has finished. |

## Development

`make regen` from the repository root rewrites `types.generated.go`; do not edit it by hand.
`make contracts-go` vets, format-checks and tests the module.
