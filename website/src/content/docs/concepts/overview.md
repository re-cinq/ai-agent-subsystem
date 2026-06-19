---
title: Overview
description: The problem ai-agent-subsystem solves and the core ideas behind it.
---

ai-agent-subsystem runs autonomous coding agents as Kubernetes workloads. Instead of a bespoke job
queue, agents are described declaratively as Custom Resources and reconciled by a controller, the
same way you would manage any other Kubernetes object.

## The problem

Running an agent reliably means orchestrating a lot of moving parts: a prompt, a model, a set of
tool permissions, a container with the right runtime, credentials, a deadline, output capture, and
cleanup. Doing that ad hoc per run is fragile and hard to audit.

## The approach

Three small ideas carry the whole design.

### Kubernetes is the source of truth

There is no external orchestration database. A run *is* an `Agent` resource. Its desired state lives
in `spec`; its observed state lives in `status`. The controller's only job is to make the two agree.

### Separate the recipe, the runtime, and the run

- The **recipe** (`AgentDefinition`) is reusable and environment-independent: what to do, with which
  model and tools.
- The **runtime** (`Station`) is the Pod template the recipe runs in, plus history limits.
- The **run** (`Agent`) is a single execution with its own parameters.

The same recipe can run in many stations; the same station can serve many runs.

### The injected-kernel runtime

Stations do not need to bake the agent toolchain into their image. An init container copies the
agent runtime (the language runtime, the agent CLI, and a supervisor) into a shared volume, and the
main container runs the supervisor as its entrypoint. Any glibc-based image can be a station.

See [How the pieces relate](/concepts/relationships/) for the full schema, or jump
to the [Architecture](/concepts/architecture/) for the component design.
