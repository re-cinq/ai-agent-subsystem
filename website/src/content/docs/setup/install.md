---
title: Install
description: Install the subsystem with a single kubectl apply, then verify the deployment.
---

Each release ships a single `install.yaml` that bundles the namespace, the Custom Resource
Definitions, the controller's RBAC and NetworkPolicy, and the controller Deployment. One
`kubectl apply` stands the whole subsystem up in its own namespace.

:::note
`install.yaml` is rendered from `deploy/` at release time with the controller and agent images pinned
to the exact cosign-signed digests that release built — no floating `:latest`. Working from a source
checkout before a release exists? Use `kubectl apply -k deploy` instead (see below).
:::

## Install

```sh
kubectl apply -f https://github.com/re-cinq/ai-agent-subsystem/releases/latest/download/install.yaml
```

To pin a specific version instead of tracking the latest release:

```sh
kubectl apply -f https://github.com/re-cinq/ai-agent-subsystem/releases/download/v0.1.0/install.yaml
```

### From a source checkout

Before a release is published — or when developing against the manifests directly — apply the
`deploy/` kustomization:

```sh
kubectl apply -k deploy
```

The controller runs least-privilege: it can watch and patch Agents, read Stations and
AgentDefinitions, manage Jobs, and read pod logs. See [RBAC & network](/reference/rbac-and-network/).

## Verify the deployment

```sh
kubectl -n ai-agents get deploy,pods
kubectl -n ai-agents logs deploy/agent-controller
```

The controller exposes `/healthz` and a Prometheus `/metrics` endpoint on its health port; a
`Running` pod with passing probes means it is reconciling. The pod template carries
`prometheus.io/scrape` annotations, so a cluster Prometheus picks up `/metrics` automatically.

## Verify the release

The controller image `install.yaml` pins is signed in CI with [cosign](https://docs.sigstore.dev/)
(keyless, via the GitHub OIDC token). Confirm the signature before trusting a release:

```sh
cosign verify ghcr.io/re-cinq/ai-agent-controller@sha256:127f548800e2682752b84757d0f294433486026a868ddbb5320f36c592b57838 \
  --certificate-identity-regexp '^https://github.com/re-cinq/ai-agent-subsystem/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The digest above is the one this release's `install.yaml` references. A passing check means the image
was built and signed by this repository's release workflow. The same images also carry an SPDX SBOM
and SLSA provenance attestation; see [Releases](https://github.com/re-cinq/ai-agent-subsystem#releases).

## Next

Define your first recipe in [Define a recipe](/tasks/define-a-recipe/), or jump
straight to the [Examples](/tasks/examples/).
