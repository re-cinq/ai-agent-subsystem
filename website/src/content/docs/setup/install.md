---
title: Install
description: Install the subsystem with a single kubectl apply or the Helm chart, then verify the deployment.
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
kubectl apply -f https://github.com/re-cinq/ai-agent-subsystem/releases/download/v0.14.0/install.yaml
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
TAG=v0.14.0

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

## Install with Helm

Each release also publishes a Helm chart to `oci://ghcr.io/re-cinq/charts`. It is packaged from
`deploy/`, and CI fails if the two render different objects, so a Helm install creates the same
objects as `install.yaml` for the same release. Helm 3.8 or later is needed for OCI charts.

```sh
helm install ai-agent-subsystem oci://ghcr.io/re-cinq/charts/ai-agent-subsystem --version 0.14.0 \
  --namespace default
```

The chart creates the `ai-agents` namespace itself, as `install.yaml` does, and every object goes
there. `--namespace` only chooses where Helm keeps its release record, so it must name a namespace
that already exists. Do not pass `--namespace ai-agents --create-namespace`: Helm would create the
namespace first and then fail on the chart's own Namespace object.

| Value | Default | Effect |
| --- | --- | --- |
| `controller.image.repository` | `ghcr.io/re-cinq/ai-agent-controller` | Controller image, without tag or digest |
| `controller.image.digest` | the release's signed digest | Controller image digest (`sha256:…`). Tags are rejected |
| `agentImage` | `ghcr.io/re-cinq/ai-agent@sha256:…` | Agent runtime image injected into run pods. Must be digest-pinned |
| `batch.enabled` | `false` | Same as the `components/batch` component: [batch runs](#enable-batch-runs-optional) |
| `modelCatalog.enabled` | `false` | Same as the `components/model-catalog` component: [model catalog](#enable-the-model-catalog-optional) |
| `realtime.enabled` | `false` | Same as the `components/realtime` component: [realtime sessions](#enable-realtime-sessions-optional). Create the `agent-realtime` Secret first |
| `webhooks.enabled` | `false` | Same as the `components/webhooks` component: [GitHub webhooks](#enable-github-webhooks-optional). Store the HMAC key in `agent-secrets` first |

The chart accepts no other values. For a private registry, set `controller.image.repository`,
`controller.image.digest` and `agentImage` to your own images.

Helm installs the CRDs from the chart's `crds/` directory on the first install only. `helm upgrade`
does not change them and `helm uninstall` leaves them in place. When a release changes a CRD, apply
that release's CRDs yourself (this uses [yq](https://github.com/mikefarah/yq) to pick them out of
`install.yaml`):

```sh
curl -sL https://github.com/re-cinq/ai-agent-subsystem/releases/download/v0.14.0/install.yaml \
  | yq 'select(.kind == "CustomResourceDefinition")' | kubectl apply -f -
```

The chart is signed with cosign the same way as the images:

```sh
cosign verify ghcr.io/re-cinq/charts/ai-agent-subsystem:0.14.0 \
  --certificate-identity-regexp '^https://github.com/re-cinq/ai-agent-subsystem/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The same chart is attached to each [GitHub release](https://github.com/re-cinq/ai-agent-subsystem/releases)
as `ai-agent-subsystem-<version>.tgz`, for tools that cannot pull OCI charts.

## Enable batch runs (optional)

[Batch runs](../tasks/batch-runs.md) are off by default, and neither `install.yaml` nor `deploy/`
gives the controller access to Secrets. To enable them, install through your own kustomization that
adds the `components/batch` component:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy?ref=v0.14.0
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/batch?ref=v0.14.0
```

```sh
kubectl apply -k .
```

From a source checkout, list `deploy` and `deploy/components/batch` as local paths instead. With
[Helm](#install-with-helm), set `batch.enabled=true`.

## Enable realtime sessions (optional)

[Realtime sessions](../tasks/realtime-sessions.md) are off by default. To enable them, create the
`agent-realtime` Secret and add the `components/realtime` component; the
[guide](../tasks/realtime-sessions.md#enable-realtime-on-the-controller) has both steps. With
[Helm](#install-with-helm), create the Secret and set `realtime.enabled=true`.

## Enable GitHub webhooks (optional)

[GitHub webhooks](../tasks/trigger-from-github.md) are off by default. To enable them, add the
`components/webhooks` component, which grants the controller `get` on the `agent-secrets` Secret,
sets `WEBHOOKS_ENABLED=true` and adds the `agent-controller-webhooks` Service on port 8083:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy?ref=v0.14.0
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/webhooks?ref=v0.14.0
```

Then store the webhook's HMAC key in `agent-secrets`, expose the Service to GitHub and add the
webhook; the [guide](../tasks/trigger-from-github.md) has each step. From a source checkout, use
`deploy/components/webhooks` as a local path. With [Helm](#install-with-helm), set `webhooks.enabled=true`
instead of adding the component.

## Enable the model catalog (optional)

The [ModelCatalog](../reference/crd-modelcatalog.md) lists the models the subsystem can run with the
API keys in `agent-secrets`. It is off by default. To enable it, add the `components/model-catalog`
component, which grants the controller `get` on the `agent-secrets` Secret and sets
`MODEL_CATALOG_ENABLED=true`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy?ref=v0.14.0
components:
  - https://github.com/re-cinq/ai-agent-subsystem//deploy/components/model-catalog?ref=v0.14.0
```

List both components to enable batch runs and the catalog together. From a source checkout, use
`deploy/components/model-catalog` as a local path. With [Helm](#install-with-helm), set
`modelCatalog.enabled=true`. Once the controller has refreshed, read the
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
cosign verify ghcr.io/re-cinq/ai-agent-controller@sha256:c1abb59da048e98329caf04ffc1c2bde41736e10a140307b83e848fefabb92c4 \
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
