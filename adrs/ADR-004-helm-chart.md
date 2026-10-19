---
adr_number: 4
title: Helm chart — a drift-checked packaging of deploy/, with kustomize as the source of truth
status: accepted
date: 2026-10-17
domains: [deployment, operations, security]
amends: 3
---

# ADR-004 — Helm chart: a drift-checked packaging of deploy/

## Status

Accepted. Amends [ADR-003](ADR-003-deployment.md).

## Context

ADR-003 chose kustomize over Helm because the manifests are small and stable, and kustomize
`images:` overlays cover the main customisation point. That still holds for authoring the manifests.
It does not help platform teams that install operators only through Helm, often from an Argo CD or
Flux Helm source. For them `kubectl apply -f install.yaml` and `kubectl apply -k deploy` are not an
option, so they never try the project.

A Helm chart maintained next to `deploy/` would be a second copy of every object. Without a check,
the two copies drift apart: a fix lands in `deploy/` and the chart keeps shipping the old manifest.

## Decision

1. **Kustomize stays the source of truth.** `deploy/` and `deploy/components/*` are where manifests
   are authored and reviewed. `install.yaml` is still rendered from `deploy/`.
2. **The chart is a thin packaging of `deploy/`**, at `deploy/helm/ai-agent-subsystem/`. Its
   templates are the `deploy/` objects with a few values substituted. It adds no objects, labels or
   annotations of its own. The namespace stays `ai-agents`, as in `deploy/`.
3. **Values are limited to what `deploy/` already varies**: `controller.image.repository` and
   `controller.image.digest`, `agentImage`, and the toggles `batch.enabled`, `modelCatalog.enabled`
   and `realtime.enabled`, one for each of `deploy/components/*`. `values.schema.json` rejects
   anything else, and it rejects image references that are not digest-pinned.
4. **CRDs ship in the chart's `crds/`**, as a copy of `deploy/crds` that `make regen` writes.
5. **Drift is a build failure.** `scripts/check-helm-drift.sh` renders `helm template` and
   `kubectl kustomize` for the default values and for each toggle (with deploy/ plus the matching
   component), normalises both, and diffs them. It runs in `make drift`, so it also runs in the
   pre-push hook and in CI.
6. **Released like the images.** On a `v*` tag the release job packages the chart from the same
   digest-pinned checkout that renders `install.yaml`, pushes it to `oci://ghcr.io/re-cinq/charts`,
   cosign-signs the pushed digest (keyless), and attaches the `.tgz` to the GitHub Release.
   `scripts/pin-image-digests.sh` rewrites the chart's image digests and its version with
   `deploy/`.

## Rationale

- **One source, two packagings**: authors keep editing plain manifests and kustomize components;
  Helm users get the same objects. The drift check is what makes "the same" true. It compares
  rendered objects, so a missed edit fails `make drift` before review.
- **Few values on purpose**: every value is a way for the chart's output to differ from
  `install.yaml`. The issue to solve is the install channel, not more configuration. Teams that need
  more can render the chart and patch it, as they would `deploy/`.
- **Digest-only images**: ADR-003 rules out floating tags in production manifests. Having only a
  digest field and a schema check keeps that rule for Helm installs as well.
- **OCI + cosign**: GHCR already hosts the signed images. An OCI chart in the same registry is
  signed and verified with the same keyless identity, so there is no separate Helm repository index
  to host or trust.

## Consequences

- Every change to `deploy/` or `deploy/components/*` also needs the same change in the chart's
  `templates/`, or `make drift` fails. CRD changes only need `make regen`.
- `make drift` now needs `helm`, `kubectl` and python3 with PyYAML. CI installs a pinned Helm.
- Helm installs CRDs from `crds/` on first install only and never upgrades them. Upgrading the
  CRDs on a Helm install means applying `deploy/crds` (or the release's `install.yaml` CRDs) with
  `kubectl apply`.
- The chart contains the `ai-agents` Namespace object, as `deploy/` does. A Helm release must
  therefore be stored in a namespace that already exists, not in `ai-agents` via `--create-namespace`.
- Each release publishes one more signed artifact, `ghcr.io/re-cinq/charts/ai-agent-subsystem`, whose
  version is the release tag without the leading `v`.
