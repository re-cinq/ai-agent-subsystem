# syntax=docker/dockerfile:1
#
# Real-container test image for ai-agent-init. The builder and runtime use the
# SAME base distro so the glibc the binary is linked against matches at run time.
# The runtime is a minimal image where git/curl are absent, so running the binary
# exercises the package-manager self-bootstrap path for real.
#
#   build args: BUILDER_IMAGE (has a D toolchain installed here), RUNTIME_IMAGE
#
ARG BUILDER_IMAGE=debian:bookworm
ARG RUNTIME_IMAGE=debian:bookworm-slim

FROM ${BUILDER_IMAGE} AS builder
RUN set -eu; \
	if command -v apt-get >/dev/null 2>&1; then \
		export DEBIAN_FRONTEND=noninteractive; \
		apt-get update; \
		apt-get install -y --no-install-recommends ldc dub gcc lld libc6-dev zlib1g-dev git ca-certificates; \
		rm -rf /var/lib/apt/lists/*; \
	elif command -v dnf >/dev/null 2>&1; then \
		dnf install -y ldc dub gcc lld glibc-devel zlib-devel git; dnf clean all; \
	else \
		echo "no supported builder package manager" >&2; exit 1; \
	fi
WORKDIR /src
COPY . .
# Link druntime/phobos statically so the binary is self-contained and runs on a
# minimal runtime image with no D shared libraries. `-L-lz` resolves std.zlib,
# which the static phobos drags in. Linked with lld, as every LDC build is: an ld.bfd
# older than 2.36 (a bullseye or Rocky 9 BUILDER_IMAGE) splits .tbss, so thread-locals
# alias (see scripts/check-tbss.sh).
RUN DFLAGS="-link-defaultlib-shared=false -L-lz --linker=lld" dub build :initializer --compiler=ldc2
RUN scripts/check-tbss.sh packages/initializer/ai-agent-init

# A throwaway origin repo to clone from, built where git exists.
RUN git config --global user.email t@example.com; \
	git config --global user.name ctest; \
	mkdir -p /origin; cd /origin; git init -q; \
	echo hello > README.md; git add README.md; \
	git -c commit.gpgsign=false commit -qm init; git tag v1

FROM ${RUNTIME_IMAGE} AS runtime
COPY --from=builder /src/packages/initializer/ai-agent-init /usr/local/bin/ai-agent-init
COPY --from=builder /origin /origin
COPY scripts/container/run-init.sh /usr/local/bin/run-init.sh
RUN chmod +x /usr/local/bin/run-init.sh
ENTRYPOINT ["/usr/local/bin/run-init.sh"]
