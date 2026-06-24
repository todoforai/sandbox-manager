# Sandbox rootfs as an OCI image for Kata Containers + Firecracker.
#
# Replaces the old build-ubuntu-rootfs.sh ext4 image. Everything the old /init
# did at boot (networking, clock, /dev mounts, recovery sshd) is now handled by
# Kata's guest agent — so this image only needs: the userland tools, the bridge
# binary, and the bridge as ENTRYPOINT reading ENROLL_TOKEN from the env.
#
# Build: scripts/build-oci.sh   (wraps `docker build` with the bridge binary)

FROM ubuntu:24.04

ARG PACKAGES="iproute2 ca-certificates bash coreutils util-linux curl wget jq unzip openssh-client socat sudo ripgrep fd-find patch rclone gh git"

ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C HOME=/root

RUN apt-get update \
 && apt-get install -y --no-install-recommends $PACKAGES \
 && ( [ -x /usr/bin/fdfind ] && ln -sf /usr/bin/fdfind /usr/local/bin/fd || true ) \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /usr/share/man/* /usr/share/doc/* /usr/share/info/*

# bun: runtime + package manager for npm catalog CLIs (agent-browser, tfa-vault).
RUN export BUN_INSTALL=/usr/local \
 && curl -fsSL https://bun.sh/install | bash \
 && ln -sf /usr/local/bin/bun /usr/local/bin/bunx \
 && ln -sf /usr/local/bin/bun /usr/local/bin/node

# Catalog CLIs tagged preinstallCloud (passed in as a space-separated build arg
# so the package list stays the single source of truth in tool_catalog.json).
ARG BUN_PREINSTALL=""
RUN if [ -n "$BUN_PREINSTALL" ]; then export BUN_INSTALL=/usr/local && bun add -g $BUN_PREINSTALL; fi

# The bridge binary — built/fetched by build-oci.sh and dropped next to this
# Dockerfile as `todoforai-bridge`. The entrypoint redeems ENROLL_TOKEN then
# execs the daemon (see oci/entrypoint.sh).
COPY todoforai-bridge /usr/local/bin/todoforai-bridge
COPY entrypoint.sh /usr/local/bin/sandbox-entrypoint
RUN chmod +x /usr/local/bin/todoforai-bridge /usr/local/bin/sandbox-entrypoint

# Self-classify as a sandbox device at enroll time (bridge reads this).
RUN touch /etc/todoforai-sandbox

# DNS resolvers baked into the image. The microVM has no DHCP/resolved to write
# /etc/resolv.conf, and Kata won't inject one (unlike Docker at runtime), so the
# guest would have no resolver and DNS fails (HTTPS to api.todofor.ai times
# out). Public anycast resolvers (oci/resolv.conf); swap that file if a host
# firewalls outbound DNS to its own resolvers.
COPY resolv.conf /etc/resolv.conf

WORKDIR /root
ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
