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

:::caution[The agent runtime image is private]
`ghcr.io/re-cinq/ai-agent-controller` is public, but the agent runtime image
`ghcr.io/re-cinq/ai-agent` — the one the controller injects into every run pod — is **not**. The
published `install.yaml` references it by digest, so applying it on an arbitrary cluster stands the
controller up and then fails every run with `ImagePullBackOff`.

If you are outside the re-cinq org, [build both images from source](#build-your-own-images) and
install pointing at your own registry.
:::

## Install

```sh
kubectl apply -f https://github.com/re-cinq/ai-agent-subsystem/releases/latest/download/install.yaml
```

To pin a specific version instead of tracking the latest release:

```sh
kubectl apply -f https://github.com/re-cinq/ai-agent-subsystem/releases/download/v0.10.0/install.yaml
```

### Build your own images

You need Docker (with Buildx) and a registry your cluster can pull from. Both images build from the
repository root:

```sh
REGISTRY=your-registry.example.com/your-project
TAG=v0.10.0

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
cosign verify ghcr.io/re-cinq/ai-agent-controller@sha256:f38716c5cb74275d2f64b57f21c8d13e78760b5aea41d8abb78cdfd8bb5cd633 \
  --certificate-identity-regexp '^https://github.com/re-cinq/ai-agent-subsystem/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The digest above is the one this release's `install.yaml` references. A passing check means the image
was built and signed by this repository's release workflow. The same images also carry an SPDX SBOM
and SLSA provenance attestation; see [Releases](https://github.com/re-cinq/ai-agent-subsystem#releases).

## Next

Define your first recipe in [Define a recipe](../tasks/define-a-recipe.md), or jump
straight to the [Examples](../tasks/examples.md).
