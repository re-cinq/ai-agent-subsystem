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
kubectl apply -f https://github.com/re-cinq/ai-agent-subsystem/releases/download/v0.13.0/install.yaml
```

Then [verify the deployment](#verify-the-deployment). One thing `install.yaml` cannot ship for you is
credentials: an agent calls a model provider, so it needs an `agent-secrets` Secret in the
`ai-agents` namespace before a run can succeed. See
[Prerequisites](./prerequisites.md#credentials).

### Build your own images

You do **not** need this to install — the published images are public. Build your own only when the
cluster must pull from a private or air-gapped registry of your own.

The published images are multi-arch (linux/amd64 and linux/arm64). You need Docker (with Buildx)
and a registry your cluster can pull from. Both images build from the repository root, for the
platforms your nodes run:

```sh
REGISTRY=your-registry.example.com/your-project
TAG=v0.13.0

docker buildx build --platform linux/amd64,linux/arm64 --push \
  -f deploy/Dockerfile.controller       -t "$REGISTRY/ai-agent-controller:$TAG" .
docker buildx build --platform linux/amd64,linux/arm64 --push \
  -f scripts/container/Dockerfile.agent -t "$REGISTRY/ai-agent:$TAG"            .
```

Building a platform other than the host's needs QEMU `binfmt` registered (`docker run --privileged
--rm tonistiigi/binfmt --install arm64`) or a native builder of that architecture; drop the one you
do not need from `--platform` to skip it.

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
AgentDefinitions, manage Jobs, read pod logs, and write the
[ModelCatalog](../reference/crd-modelcatalog.md). See [RBAC & network](../reference/rbac-and-network.md).

## Enable batch runs (optional)

[Batch runs](../tasks/batch-runs.md) are off by default, and neither `install.yaml` nor `deploy/`
gives the controller access to Secrets. To enable them, install through your own kustomization that
adds the `components/batch` component:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy?ref=v0.13.0
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/batch?ref=v0.13.0
```

```sh
kubectl apply -k .
```

From a source checkout, list `deploy` and `deploy/components/batch` as local paths instead.

## Enable realtime sessions (optional)

[Realtime sessions](../tasks/realtime-sessions.md) are off by default. To enable them, create the
`agent-realtime` Secret and add the `components/realtime` component; the
[guide](../tasks/realtime-sessions.md#enable-realtime-on-the-controller) has both steps.

## Enable GitHub webhooks (optional)

[GitHub webhooks](../tasks/trigger-from-github.md) are off by default. To enable them, add the
`components/webhooks` component, which grants the controller `get` on the `agent-secrets` Secret,
sets `WEBHOOKS_ENABLED=true` and adds the `agent-controller-webhooks` Service on port 8083:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy?ref=v0.13.0
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/webhooks?ref=v0.13.0
```

Then store the webhook's HMAC key in `agent-secrets`, expose the Service to GitHub and add the
webhook; the [guide](../tasks/trigger-from-github.md) has each step. From a source checkout, use
`deploy/components/webhooks` as a local path.

## Enable the model catalog (optional)

The [ModelCatalog](../reference/crd-modelcatalog.md) lists the models the subsystem can run with the
API keys in `agent-secrets`. It is off by default. To enable it, add the `components/model-catalog`
component, which grants the controller `get` on the `agent-secrets` Secret and sets
`MODEL_CATALOG_ENABLED=true`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy?ref=v0.13.0
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/model-catalog?ref=v0.13.0
```

List both components to enable batch runs and the catalog together. From a source checkout, use
`deploy/components/model-catalog` as a local path. Once the controller has refreshed, read the
catalog with `kubectl get mc default -n ai-agents -o yaml`.

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
cosign verify ghcr.io/re-cinq/ai-agent-controller@sha256:e3fdada1fa1fd5f62e59b57041b9c284b5ef8f7e61769d6533c94f6b82ce94d5 \
  --certificate-identity-regexp '^https://github.com/re-cinq/ai-agent-subsystem/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The digest above is the one this release's `install.yaml` references. A passing check means the image
was built and signed by this repository's release workflow. The same images also carry an SPDX SBOM
and SLSA provenance attestation; see [Releases](https://github.com/re-cinq/ai-agent-subsystem#releases).

## API versions and upgrading

The CRDs are served at `agents.re-cinq.com/v1beta1`, which is also the version objects are stored
at. `v1alpha1` is still served with the identical schema, so manifests and clients written for it
keep working after an upgrade; the API server answers each `v1alpha1` request with a deprecation
warning. Nothing needs converting: both versions read and write the same fields.

Objects created before the upgrade stay stored as `v1alpha1` until they are next written. Before a
future release stops serving `v1alpha1`, rewrite them once so every object is stored at `v1beta1`:

```sh
for kind in agentdefinitions stations agents modelcatalogs; do
  kubectl get "$kind.agents.re-cinq.com" -A -o json | kubectl replace -f -
done
```

`kubectl get crd agents.agents.re-cinq.com -o jsonpath='{.status.storedVersions}'` lists the versions
the CRD has recorded as stored. The API server never prunes that list itself; once the rewrite is
done, drop `v1alpha1` from it (`kubectl patch crd <name> --subresource=status --type=merge -p
'{"status":{"storedVersions":["v1beta1"]}}'`).

## Next

Define your first recipe in [Define a recipe](../tasks/define-a-recipe.md), or jump
straight to the [Examples](../tasks/examples.md). To tear it all back down, see
[Uninstall](./uninstall.md).
