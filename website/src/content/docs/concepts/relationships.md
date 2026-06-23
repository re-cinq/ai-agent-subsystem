---
title: How the pieces relate
description: "The relationship schema for ai-agent-subsystem: the data model and the runtime composition."
---

This page is the schema hub. The first diagram shows how the resources reference one another and
what each carries; the second shows how those references turn into a running Pod.

## Data model

`AgentDefinition`, `Station`, and `Agent` form a reference chain. The controller turns an `Agent`
into a `Job`, which Kubernetes turns into a `Pod`.

```mermaid
erDiagram
    AgentDefinition ||--o{ Station : "agentDefRef"
    Station ||--o{ Agent : "stationRef"
    Agent ||--|| Job : "creates and owns"
    Job ||--|| Pod : "spawns"

    AgentDefinition {
        string prompt "template with placeholders"
        string model "default claude-sonnet-4-6"
        list allowed_tools "permission rules"
        enum permission_mode "auto or bypass"
        object resources "env, secrets, repos, mcp"
        object output "format, sinks, select"
    }
    Station {
        string agentDefRef "recipe to run"
        int deadlineMinutes "default 30"
        int successfulRunsHistoryLimit "default 3"
        int failedRunsHistoryLimit "default 3"
        object template "PodTemplateSpec"
    }
    Agent {
        string stationRef "where to run"
        map parameters "fill the prompt"
        string targetRepo "owner/name"
        string branch "git branch"
        enum phase "Pending Running Succeeded Failed"
        string jobName "created job"
    }
    Job {
        int activeDeadlineSeconds "deadlineMinutes x 60"
        int ttlSecondsAfterFinished "3600"
        int backoffLimit "1"
    }
    Pod {
        string initContainer "inject bundle"
        string mainContainer "supervisor"
        string bundleVolume "emptyDir /lore"
    }
```

Read the edges as references:

- A **Station** names exactly one **AgentDefinition** through `spec.agentDefRef`. Many stations may
  point at the same recipe.
- An **Agent** names exactly one **Station** through `spec.stationRef`. Many runs may use the same
  station.
- The controller creates one **Job** per Agent and sets an owner reference, so deleting the Agent
  garbage-collects the Job.
- The **Job** produces one **Pod** that does the work.

## Runtime composition

When the controller reconciles a `Pending` Agent it renders the prompt, clones the Station's Pod
template, and assembles the Pod below. The agent toolchain is *injected* into a shared volume rather
than baked into the Station image.

```mermaid
flowchart LR
    PARM["Agent.parameters"] --> RENDER["render prompt<br/>(fill placeholders)"]
    RENDER --> JOB["Job<br/>(template from Station)"]

    subgraph POD["Agent Pod"]
        direction TB
        INIT["initContainer<br/>inject-agent"] -->|copies runtime + CLI + supervisor| VOL[("emptyDir /lore")]
        VOL --> SUP["main container<br/>supervisor"]
        SUP --> PROC["agent process"]
        CREDS[("credentials volume")] -.-> SUP
    end

    JOB --> POD
    PROC --> SINK["output sinks<br/>stdout / http"]
    NETPOL{{"egress-only NetworkPolicy<br/>DNS + HTTPS"}} -.-> POD
```

The same model is described from the controller's perspective in
[Controller lifecycle](/concepts/controller-lifecycle/) and from the pod's
perspective in [Agent runtime](/concepts/agent-runtime/).
