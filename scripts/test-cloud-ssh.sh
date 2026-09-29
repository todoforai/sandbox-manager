#!/bin/bash
# Local check of the guest cloud-SSH bits (oci/cloud-ssh): builds a minimal
# Ubuntu image with the same user/config setup as oci/Dockerfile and runs a
# real sshd login, key denial, forwarding denial, SFTP and rsync against a
# fake authorized-key backend. Needs docker; touches no VM.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ctx=$(mktemp -d); trap 'rm -rf "$ctx"' EXIT
cp -r "$ROOT/oci/cloud-ssh" "$ROOT/scripts/cloud-ssh-test/smoke-in-container.sh" "$ctx/"
cat > "$ctx/Dockerfile" <<'DOCKER'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server openssh-client rsync jq curl iproute2 util-linux python3 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY cloud-ssh/sshd_config /etc/ssh/cloud-sshd_config
COPY cloud-ssh/cloud-ssh-setup /usr/local/sbin/cloud-ssh-setup
COPY cloud-ssh/cloud-ssh-authorized-key /usr/local/libexec/cloud-ssh-authorized-key
COPY smoke-in-container.sh /smoke.sh
DOCKER
# Same user/key setup as oci/Dockerfile.
sed -n '/^RUN rm -f \/etc\/ssh\/ssh_host_\*/,/cloud-ssh-authorized-key$/p' "$ROOT/oci/Dockerfile" >> "$ctx/Dockerfile"
docker build -q -t cloud-ssh-test "$ctx" >/dev/null
docker run --rm --cap-add SYS_ADMIN --security-opt apparmor=unconfined cloud-ssh-test bash /smoke.sh
