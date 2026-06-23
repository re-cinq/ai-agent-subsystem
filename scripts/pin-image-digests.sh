#!/usr/bin/env bash
# Pin deploy/ to immutable image digests for a published ref (default: latest).
#
# A digest (sha256:...) names an exact image; a tag is mutable. Pinning makes
# `kubectl apply -k deploy` deploy a reproducible, tamper-evident image set — the
# same digests cosign signs in .github/workflows/images.yml.
#
# Rewrites, in place:
#   - deploy/kustomization.yaml                 images[ai-agent-controller]  newTag/digest -> digest
#   - deploy/controller.yaml                    env AGENT_IMAGE              tag/@digest    -> @digest
#   - website/.../setup/install.md              cosign verify <controller>@  @digest        -> @digest
#
# Resolving a digest from a tag needs registry read access (docker login ghcr.io
# with a read:packages token). In CI the build already emitted the digests, so
# pass them in and no registry read happens:
#   CONTROLLER_DIGEST=sha256:... AGENT_DIGEST=sha256:... scripts/pin-image-digests.sh vX.Y.Z
#
#   usage: scripts/pin-image-digests.sh [REF]      # REF defaults to "latest"
set -euo pipefail

ref="${1:-latest}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
controller="ghcr.io/re-cinq/ai-agent-controller"
agent="ghcr.io/re-cinq/ai-agent"

digest() { # digest <image> -> sha256:...
	docker buildx imagetools inspect "$1:$ref" --format '{{.Manifest.Digest}}'
}

controller_digest="${CONTROLLER_DIGEST:-$(digest "$controller")}"
agent_digest="${AGENT_DIGEST:-$(digest "$agent")}"

# Controller: replace the image's `newTag:`/`digest:` line with the digest.
python3 - "$repo/deploy/kustomization.yaml" "$controller" "$controller_digest" <<'PY'
import re, sys
path, name, digest = sys.argv[1:4]
text = open(path).read()
pat = re.compile(r"(- name: " + re.escape(name) + r"\n(\s+))(newTag|digest): .*")
new, n = pat.subn(lambda m: m.group(1) + "digest: " + digest, text)
if n != 1:
    sys.exit(f"expected one images entry for {name}, patched {n}")
open(path, "w").write(new)
PY

# Agent: injected via the AGENT_IMAGE env, not a manifest image field, so pin it
# directly in the Deployment.
python3 - "$repo/deploy/controller.yaml" "$agent" "$agent_digest" <<'PY'
import re, sys
path, name, digest = sys.argv[1:4]
text = open(path).read()
new, n = re.subn(re.escape(name) + r"(?:@sha256:[0-9a-f]+|:[^\s\"']+)", name + "@" + digest, text)
if n < 1:
    sys.exit(f"AGENT_IMAGE reference {name} not found in {path}")
open(path, "w").write(new)
PY

# Docs: the install page shows `cosign verify <controller>@sha256:...` so readers
# verify the exact image this release pins. Keep that digest in lockstep too.
python3 - "$repo/website/src/content/docs/setup/install.md" "$controller" "$controller_digest" <<'PY'
import re, sys
path, name, digest = sys.argv[1:4]
text = open(path).read()
new, n = re.subn(re.escape(name) + r"@sha256:[0-9a-f]+", name + "@" + digest, text)
if n < 1:
    sys.exit(f"cosign verify reference {name} not found in {path}")
open(path, "w").write(new)
PY

# Fail loudly if any rewrite did not land a digest — a release must never ship a
# floating tag, and the docs must verify the image it actually pins.
grep -q "digest: ${controller_digest}" "$repo/deploy/kustomization.yaml" \
	|| { echo "pin failed: controller digest not written to deploy/kustomization.yaml" >&2; exit 1; }
grep -q "@${agent_digest}" "$repo/deploy/controller.yaml" \
	|| { echo "pin failed: agent digest not written to deploy/controller.yaml" >&2; exit 1; }
grep -q "@${controller_digest}" "$repo/website/src/content/docs/setup/install.md" \
	|| { echo "pin failed: controller digest not written to setup/install.md" >&2; exit 1; }

echo "pinned controller@${controller_digest}  agent@${agent_digest}  (ref=${ref})"
