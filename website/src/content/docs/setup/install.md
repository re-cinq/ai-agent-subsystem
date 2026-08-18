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

Both images are public, so there is nothing to build, mirror or authenticate against first. You need
a cluster, `kubectl`, and permission to create cluster-scoped resources (the CRDs) — see
[Prerequisites](./prerequisites.md).

## Install

```sh
kubectl apply -f https://github.com/re-cinq/ai-agent-subsystem/releases/latest/download/install.yaml
```

That is the entire install. To pin a specific release instead of tracking the latest, substitute a
tag from the [releases page](https://github.com/re-cinq/ai-agent-subsystem/releases):

```sh
kubectl apply -f https://github.com/re-cinq/ai-agent-subsystem/releases/download/v0.10.6/install.yaml
```

Then [verify the deployment](#verify-the-deployment). One thing `install.yaml` cannot ship for you is
credentials: an agent calls a model provider, so it needs an `agent-secrets` Secret in the
`ai-agents` namespace before a run can succeed. See
[Prerequisites](./prerequisites.md#credentials).

### Build your own images

You do **not** need this to install — the published images are public. Build your own only when the
cluster must pull from a private or air-gapped registry of your own.

You need Docker (with Buildx) and a registry your cluster can pull from. Both images build from the
repository root:

```sh
REGISTRY=your-registry.example.com/your-project
TAG=v0.10.6

docker build -f deploy/Dockerfile.controller       -t "$REGISTRY/ai-agent-controller:$TAG" .
docker build -f scripts/container/Dockerfile.agent -t "$REGISTRY/ai-agent:$TAG"            .

docker push "$REGISTRY/ai-agent-controller:$TAG"
docker push "$REGISTRY/ai-agent:$TAG"
```

Then point the manifests at them. The controller image is set through the kustomize `images:`
override in `deploy/kustomization.yaml`; the agent runtime is the `AGENT_IMAGE` env in
`deploy/controller.yaml`:

```sh
( cd deploy && kustomize edit set image ghcr.io/re-cinq/ai-agent-controller="$REGISTRY/ai-agent-controller:$TAG" )
# then set AGENT_IMAGE in deploy/controller.yaml to "$REGISTRY/ai-agent:$TAG"
```

If your registry needs credentials, create an image pull secret in the `ai-agents` namespace and
reference it from the controller Deployment and the injected run pods.

### From a source checkout

Before a release is published — or when developing against the manifests directly — apply the
`deploy/` kustomization:

```sh
kubectl apply -k deploy
```

The controller runs least-privilege: it can watch and patch Agents, read Stations and
AgentDefinitions, manage Jobs, and read pod logs. See [RBAC & network](../reference/rbac-and-network.md).

## Verify the deployment

```sh
kubectl -n ai-agents get deploy,pods
kubectl -n ai-agents logs deploy/agent-controller
```

The controller exposes `/healthz` (liveness), `/readyz` (readiness — green once it has reached
the API server), and a Prometheus `/metrics` endpoint on its health port; a `Running` pod with
passing probes means it is reconciling. The pod template carries
`prometheus.io/scrape` annotations, so a cluster Prometheus picks up `/metrics` automatically.

## Verify the release

The controller image `install.yaml` pins is signed in CI with [cosign](https://docs.sigstore.dev/)
(keyless, via the GitHub OIDC token). Confirm the signature before trusting a release:

```sh
cosign verify ghcr.io/re-cinq/ai-agent-controller@sha256:c7aa11b5de2de89f41502ce9ba5c0925c4ae1d127694f83a43ed7ff1debfad91 \
  --certificate-identity-regexp '^https://github.com/re-cinq/ai-agent-subsystem/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The digest above is the one this release's `install.yaml` references. A passing check means the image
was built and signed by this repository's release workflow. The same images also carry an SPDX SBOM
and SLSA provenance attestation; see [Releases](https://github.com/re-cinq/ai-agent-subsystem#releases).

## Next

Define your first recipe in [Define a recipe](../tasks/define-a-recipe.md), or jump
straight to the [Examples](../tasks/examples.md). To tear it all back down, see
[Uninstall](./uninstall.md).
