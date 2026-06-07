#!/usr/bin/env bash
# Reproducible host setup for the Go sandbox-manager dev box.
#
# Run once per machine (or after moving the repo):  ./scripts/setup-host.sh
# Re-running is safe (idempotent).
#
# It installs the host bits the SERVICE itself needs — the parts that aren't in
# the repo and would otherwise have to be done by hand on every new PC:
#
#   1. a NOPASSWD sudoers rule so PM2 (running as your user) can launch the
#      manager as root — the service needs root for containerd.sock, losetup,
#      kata-runtime, ip netns and firecracker. (see ecosystem.config.js)
#   2. the per-user home directory (/data/user-homes), owned by you.
#
# The heavy host prerequisites (devmapper thin-pool, CNI plugins, Kata +
# Firecracker, containerd config) are installed by scripts/spike-kata-fc.sh;
# this script checks they're present and points you there if not.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$REPO_DIR/sandbox-manager"
RUN_USER="${SUDO_USER:-$USER}"           # the human user PM2 runs as
DATA_DIR="${DATA_DIR:-/data}"
USER_HOMES_DIR="${USER_HOMES_DIR:-$DATA_DIR/user-homes}"
SUDOERS_FILE="/etc/sudoers.d/sandbox-manager-run"

log()  { echo -e "\n=== $* ==="; }
ok()   { echo "  ok: $*"; }
warn() { echo "  WARN: $*" >&2; }

# Re-exec under sudo so the install steps have root, but remember RUN_USER.
if [ "$EUID" -ne 0 ]; then
    exec sudo -E RUN_USER="$RUN_USER" bash "$0" "$@"
fi

log "sandbox-manager host setup (user=$RUN_USER, repo=$REPO_DIR)"

# 1. NOPASSWD sudoers rule for the manager binary -----------------------------
# The path is repo-specific, so it's generated here rather than committed.
log "1. sudoers rule -> $SUDOERS_FILE"
TMP="$(mktemp)"
cat > "$TMP" <<EOF
# Managed by sandbox-manager/scripts/setup-host.sh — do not edit by hand.
# Lets the PM2 service (running as '$RUN_USER') launch the manager as root.
# The manager needs root: containerd.sock (root:root 0660), losetup,
# kata-runtime direct-volume, ip netns, firecracker.
# SETENV: allows passing NODE_ENV (selects .env vs .env.development).
$RUN_USER ALL=(root) NOPASSWD: SETENV: $BINARY
EOF
if visudo -c -f "$TMP" >/dev/null; then
    install -m 0440 -o root -g root "$TMP" "$SUDOERS_FILE"
    ok "installed and validated"
else
    rm -f "$TMP"; echo "ERROR: generated sudoers failed validation" >&2; exit 1
fi
rm -f "$TMP"

# 2. per-user home directory --------------------------------------------------
log "2. home dir -> $USER_HOMES_DIR (owned by $RUN_USER)"
mkdir -p "$USER_HOMES_DIR"
chown "$RUN_USER:$RUN_USER" "$DATA_DIR" "$USER_HOMES_DIR" 2>/dev/null || \
    chown "$RUN_USER:$RUN_USER" "$USER_HOMES_DIR"
ok "ready"

# 3. verify heavy prerequisites (installed by spike-kata-fc.sh) ---------------
log "3. checking host prerequisites"
[ -e /dev/kvm ] && ok "/dev/kvm present" || warn "/dev/kvm missing — KVM required for Firecracker"
[ -S /run/containerd/containerd.sock ] && ok "containerd socket present" \
    || warn "containerd socket missing — run scripts/spike-kata-fc.sh"
[ -x /opt/kata/bin/kata-runtime ] && ok "kata-runtime present" \
    || warn "kata-runtime missing — run scripts/spike-kata-fc.sh"
[ -x /opt/cni/bin/bridge ] && ok "CNI plugins present" \
    || warn "CNI plugins missing — run scripts/spike-kata-fc.sh"
[ -f /etc/cni/net.d/10-sandbox.conflist ] && ok "CNI conflist present" \
    || warn "CNI conflist missing — run scripts/spike-kata-fc.sh"

log "Done. Start the service with:  pm2 start ecosystem.config.js --only sandbox-manager"
