---
title: Rust client
description: Launch and watch Agents from Rust with kube-rs and the agent-contracts crate.
---

The `agent-contracts` crate gives a Rust program the types of every resource, ready for
`kube::Api`, and a small client that creates runs, waits for them and applies recipes. The types are
generated from the same source as the CRDs, so they always match the cluster you install from the
same release.

## Install

The crate is consumed from git at a release tag:

```toml
[dependencies]
agent-contracts = { git = "https://github.com/re-cinq/ai-agent-subsystem", tag = "v0.15.0" }
kube = { version = "5", features = ["client"] }
k8s-openapi = { version = "0.29", features = ["latest"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread", "time"] }
```

Cargo finds the crate inside the repository by its name. Like every kube-rs library, it leaves the
Kubernetes API version to your application, so enable one `k8s-openapi` version feature, such as
`latest` or `v1_33`, in your own `Cargo.toml`.

## Create the client

```rust
use agent_contracts::AgentContractsClient;

let kube = kube::Client::try_default().await?; // kubeconfig, or the service account in a pod

let agents = AgentContractsClient::new(kube, ""); // "" means the ai-agents namespace
```

## Launch a run and wait for it

```rust
use std::time::Duration;

use agent_contracts::{Agent, AgentSpec};

let mut run = Agent::default();
run.metadata.generate_name = Some("fix-bug-".into());
run.spec = Some(AgentSpec {
    station_ref: "bug-fixer".into(),
    target_repo: Some("re-cinq/ai-agent-subsystem".into()),
    parameters: Some([("issue".to_string(), "123".to_string())].into()),
    ..Default::default()
});

let run = agents.create_agent(&run).await?;
let name = run.metadata.name.unwrap();

let finished = tokio::time::timeout(
    Duration::from_secs(1800),
    agents.wait_for_agent(&name, Duration::from_secs(5)),
)
.await??;

println!("{:?}", finished.status.and_then(|status| status.phase));
```

`wait_for_agent` polls until the phase is `Succeeded` or `Failed`. It never gives up on its own, so
wrap it in `tokio::time::timeout` to bound the wait.

## Apply a recipe and a runtime

```rust
use agent_contracts::{AgentDefinition, AgentDefinitionSpec};

let mut definition = AgentDefinition::new("bug-fixer");
definition.spec = Some(AgentDefinitionSpec {
    model: Some("claude-sonnet-5-5".into()),
    prompt: "Fix the bug described in issue {issue}.".into(),
    ..Default::default()
});

agents.apply_agent_definition(&definition).await?;
```

`apply_agent_definition` and `apply_station` are server-side apply with the field manager
`agent-contracts` and forced ownership. A resource without a name fails with
`Error::MissingName` before any request is sent.

## Methods

| Call | Does |
| --- | --- |
| `create_agent(&agent)` | Start one run in the client's namespace. |
| `get_agent(name)` | Read one run; an unknown name is `Error::Kube` with the API's 404. |
| `find_agents(label_selector)` | List runs matching a selector such as `team=web`. |
| `get_model_catalog()` | Read the models the subsystem can run. |
| `apply_agent_definition`, `apply_station` | Server-side apply a recipe or runtime. |
| `is_terminal(&agent)` | Whether a run has finished. |
| `wait_for_agent(name, interval)` | Poll until the run finishes. |

## Permissions

The [`agent-launcher` role](../reference/rbac-and-network.md#caller-role) covers creating, reading
and listing Agents and reading the ModelCatalog. Applying AgentDefinitions and Stations needs
`get`, `create` and `patch` on `agentdefinitions` and `stations`, which that role does not grant;
bind a separate role for the app that manages recipes.

## Types

Every kind implements `kube::Resource`, so you can also use kube-rs directly, for example
`Api::<Agent>::namespaced(client, "ai-agents")` with `kube::runtime::watcher` to react to every run.

Optional fields are `Option` and are left out when `None`, so the API server applies the CRD's
default. Free-form fields such as `StationSpec::template` are `serde_json::Value`. Enums serialize as
their wire value, and a value the crate does not know reads as the first variant, the same rule the
controller applies.

## Test without a cluster

`kube::Client::new` accepts any tower service, so a test can answer requests from memory:

```rust
let service = tower::service_fn(|request: http::Request<kube::client::Body>| async move {
    // Match on request.method() and request.uri().path(), and reply with JSON.
    Ok::<_, std::convert::Infallible>(http::Response::new(kube::client::Body::from(b"{}".to_vec())))
});

let agents = AgentContractsClient::new(kube::Client::new(service, "ai-agents"), "");
```
