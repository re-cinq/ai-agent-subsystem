---
adr_number: 3
title: Deployment approach — Kubernetes with kustomize, cosign-signed images, and one-command install
status: accepted
date: 2026-09-17
domains: [deployment, operations, security]
---

# ADR-003 — Deployment approach: Kubernetes, kustomize, cosign-signed images

## Status

Accepted

## Context

The subsystem is a Kubernetes operator. It must be installable by platform engineers who already
operate a cluster, and it must be secure enough for production use. Goals:

- Minimal install friction: a single command should stand up CRDs, RBAC, NetworkPolicy, and the
  controller.
- Supply-chain security: images must be verifiable and reproducible.
- In-cluster safety: the controller must run with least privilege.
- Cluster customisation: teams running private or air-gapped registries must be able to swap images
  without forking the manifests.

## Decision

1. **Kubernetes-native manifests** in `deploy/`: CRDs, RBAC (ServiceAccount, ClusterRole,
   ClusterRoleBinding, NetworkPolicy), and the controller Deployment, composed with **kustomize**.
2. **One-command install** via a rendered, digest-pinned `install.yaml` attached to each GitHub
   Release: `kubectl apply -f …/releases/latest/download/install.yaml`.
3. **Cosign-signed images** published to `ghcr.io/re-cinq` on every tagged release, with SPDX
   SBOMs and SLSA provenance attestations (built by the `Publish images` workflow).
4. **Digest-pinned image references** in `deploy/controller.yaml` and `deploy/kustomization.yaml`,
   kept current by `scripts/pin-image-digests.sh` on each release. Floating `:latest` tags are
   never used in production manifests.
5. **HA controller**: two replicas with leader election via a Kubernetes `Lease`. Only the Lease
   holder reconciles; standbys take over within the lease duration.
6. **Least-privilege security context**: non-root (UID 1000), `readOnlyRootFilesystem: true`,
   `allowPrivilegeEscalation: false`, all capabilities dropped, `seccompProfile: RuntimeDefault`.

## Rationale

- **Kubernetes-native**: the system's data model is already Kubernetes CRDs; managing its own
  lifecycle the same way (Deployments, RBAC) gives operators a familiar mental model and lets them
  use standard kubectl tooling.
- **Kustomize over Helm**: the manifests are small and stable; kustomize `images:` overlays cover
  the primary customisation point (private registry) without a templating language.
- **Cosign + SBOM + SLSA**: meets supply-chain security expectations for production Kubernetes
  operators; verifiable without trusting the registry.
- **Digest pinning**: prevents silent updates when an image tag is overwritten. `install.yaml`
  references the exact digest built by the release workflow, making installs reproducible.
- **HA with leader election**: Kubernetes Jobs (created by the controller) are idempotent by design;
  leader election prevents double-reconciles while still allowing fast failover.

## Consequences

- Releasing requires bumping the npm package version, pushing a git tag, and letting the
  `Publish images` workflow produce the signed images and `install.yaml`.
- Custom-registry users must build their own images (`docker build`), push them, and apply the
  kustomize overlay — documented in `README.md`.
- `deploy/controller.yaml` contains an inline digest in addition to the kustomize overlay, so
  `kubectl apply -f deploy/controller.yaml` is safe standalone; both must be updated on each release.
- Digest-pinning PRs (opened automatically by the release workflow) must be merged promptly to keep
  `main` and `kubectl apply -k deploy` in sync with the latest signed release.
