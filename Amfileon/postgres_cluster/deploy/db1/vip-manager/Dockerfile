# vip-manager has NO official Docker image (verified 2026-07-17: nothing on ghcr or
# Docker Hub) — we package the official release binary ourselves.
# TODO(later): push this to registry.amf so other hosts don't rebuild.
# NB: if the build fails with "unexpected commit digest" here, the local Docker Hub
# mirrors (registry.git.amf / dockerhub-mirror.amf) are serving stale data — fix with:
#   docker builder prune -f && docker pull debian:bookworm-slim
# TODO(later): mirror the base into registry.amf and FROM that instead.
FROM debian:bookworm-slim
ARG VERSION=4.2.0
ARG ARCH=x86_64
# iproute2 = the `ip` binary vip-manager execs to add/remove the VIP;
# iputils-arping = gratuitous ARP after raising it. Neither is in slim base images.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates iproute2 iputils-arping \
 && rm -rf /var/lib/apt/lists/*
ADD https://github.com/cybertec-postgresql/vip-manager/releases/download/v${VERSION}/vip-manager_${VERSION}_Linux_${ARCH}.tar.gz /tmp/vm.tar.gz
# Exact -name 'vip-manager' (no wildcard): the tarball ALSO contains vip-manager.yml
# (sample config) — a wildcard matches both and mv order is filesystem-dependent,
# which nondeterministically installed the YAML as the "binary" (seen on db1, 2026-07-17).
# The trailing --version run is the guard that catches any such mixup at build time.
RUN tar -xzf /tmp/vm.tar.gz -C /tmp \
 && find /tmp -name 'vip-manager' -type f -exec install -m 0755 {} /usr/local/bin/vip-manager \; \
 && rm -rf /tmp/* \
 && /usr/local/bin/vip-manager --version
ENTRYPOINT ["/usr/local/bin/vip-manager"]
