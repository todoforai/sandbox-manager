# Sandbox rootfs as an OCI image for Kata Containers + Firecracker.
#
# Replaces the old build-ubuntu-rootfs.sh ext4 image. Everything the old /init
# did at boot (networking, clock, /dev mounts, recovery sshd) is now handled by
# Kata's guest agent — so this image only needs: the userland tools, the bridge
# binary, and the bridge as ENTRYPOINT reading ENROLL_TOKEN from the env.
#
# Build: scripts/build-oci.sh   (wraps `docker build` with the bridge binary)

FROM ubuntu:24.04

ARG PACKAGES="iproute2 ca-certificates bash coreutils util-linux curl wget jq gnupg unzip openssh-client socat sudo ripgrep fd-find patch rclone gh vault"

ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C HOME=/root

# HashiCorp repo for `vault` (not in default Ubuntu repos), then the toolset.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl gnupg ca-certificates \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg \
 && chmod 0644 /etc/apt/keyrings/hashicorp-archive-keyring.gpg \
 && CODENAME=$(. /etc/os-release && echo $VERSION_CODENAME) \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $CODENAME main" > /etc/apt/sources.list.d/hashicorp.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends $PACKAGES \
 && ( [ -x /usr/bin/fdfind ] && ln -sf /usr/bin/fdfind /usr/local/bin/fd || true ) \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /usr/share/man/* /usr/share/doc/* /usr/share/info/*

# bun: runtime + package manager for the tfa-* catalog CLIs.
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

WORKDIR /root
ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
