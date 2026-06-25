---
title: Receive notifications
description: Stand up an HTTP listener, point a recipe's http sink at it, and watch a run's events arrive live.
---

A run streams its events to any `http` sink you declare. This walks through receiving them
end to end with the example listener. For the full wire format, see the
[Notification API](../reference/notification-api.md) reference.

## Run the example listener

The repository ships a zero-dependency Node.js listener that prints every POSTed event:

```sh
node examples/notify-listener.mjs
```

It listens on `:8099` (override with the first argument or `PORT`), accepts a `POST` on any
path, and answers `GET /healthz` with `ok`. It pretty-prints both lifecycle events and the
agent's `stream-json` output.

## Make it reachable from the cluster

The run pod has to reach your listener. On minikube the host is reachable from inside the
cluster at `host.minikube.internal`:

```
http://host.minikube.internal:8099/notify
```

In a real cluster, run the listener as a Service and use its in-cluster DNS name, e.g.
`http://collector.my-namespace.svc:8099/notify`.

## Point a recipe's http sink at it

Declare an `http` sink in the recipe's `output` (keep `stdout` so the pod logs still carry the
full stream):

```yaml
output:
  format: stream-json
  sinks:
    - type: stdout
    - type: http
      url: http://host.minikube.internal:8099/notify
```

See the [AgentDefinition CRD](../reference/crd-agentdefinition.md) reference for the full `output`
schema, including `select` filters and `headers_secret` for authenticated listeners.

## Launch a run and watch the events

[Launch an agent](./launch-an-agent.md) against a station using that recipe. As the run
proceeds, the listener prints each event as it arrives — first the init container's lifecycle
events, then the supervisor's `agent`/`started`, the agent's `stream-json` output, and finally
the terminal `agent`/`succeeded` (or `failed`) lifecycle event. Every line is wrapped in the
envelope, so each carries the run's `source` ids.

A failed `POST` is retried with capped exponential backoff before the event is dropped, so a
brief listener restart won't lose events; a persistently unreachable sink never blocks or fails
the run. See [Delivery & retry](../reference/notification-api.md#delivery--retry) to tune it.
