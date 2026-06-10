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

# 3. loop-device availability -------------------------------------------------
# Each running VM pins one loop device for its home.img (vm.homeDisk.Attach),
# plus 2 for the devmapper backing files. max_loop only controls how many
# devices are PRE-CREATED at boot — `losetup --find --show` allocates through
# /dev/loop-control, which creates new devices on demand far beyond max_loop
# (verified: max_loop=8 host running 40+ loops). So the only real requirement
# is loop-control being present; a missing one (ancient/custom kernel) is the
# actual hard cap.
log "3. loop-device availability (one per running VM)"
if [ -e /dev/loop-control ]; then
    ok "/dev/loop-control present — loop devices allocate on demand (max_loop is only the boot-time precreate count)"
else
    warn "/dev/loop-control missing — concurrent VMs hard-capped at max_loop=$(cat /sys/module/loop/parameters/max_loop 2>/dev/null || echo '?'); upgrade the kernel or set max_loop=4096 on the cmdline"
fi

# 4. boot-time thin-pool restore unit ----------------------------------------
# The loopback thin-pool's kernel state (loop attachments + dm target) does not
# survive reboot, so containerd's devmapper plugin fails to load and the first
# createSandbox 500s. This oneshot re-attaches the pool BEFORE containerd starts.
POOL_UNIT="/etc/systemd/system/sandbox-pool.service"
log "4. boot-time pool restore -> $POOL_UNIT"
cat > "$POOL_UNIT" <<EOF
# Managed by sandbox-manager/scripts/setup-host.sh — do not edit by hand.
[Unit]
Description=Restore devmapper sandbox-pool (loopback thin-pool) before containerd
DefaultDependencies=no
After=local-fs.target systemd-udev-settle.service
Before=containerd.service
# RequiresMountsFor pulls in (and orders after) whatever mount backs /data, so
# this still works when /data is a separate/late/nofail mount — local-fs.target
# alone wouldn't guarantee it. ConditionPathExists keeps it a no-op if the pool
# was never provisioned.
RequiresMountsFor=$DATA_DIR/devmapper
ConditionPathExists=$DATA_DIR/devmapper/data.img
ConditionPathExists=$DATA_DIR/devmapper/meta.img

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$REPO_DIR/scripts/sandbox-pool-up.sh

[Install]
# RequiredBy (not WantedBy): make containerd HARD-depend on the pool restore.
# WantedBy=/Before= alone would let containerd start anyway if restore fails,
# leaving the exact "devmapper not loaded" bug. RequiredBy means a failed
# restore blocks containerd, so the failure is loud and at the right layer
# instead of surfacing as a 500 on the first createSandbox. Also covers a
# manual 'systemctl restart containerd' (plain Before= would not pull us in).
RequiredBy=containerd.service
EOF
chmod 0644 "$POOL_UNIT"
chmod +x "$REPO_DIR/scripts/sandbox-pool-up.sh"
systemctl daemon-reload
systemctl enable sandbox-pool.service >/dev/null 2>&1 && ok "enabled (runs before containerd, incl. manual restart)" \
    || warn "could not enable sandbox-pool.service"

# 5. verify heavy prerequisites (installed by spike-kata-fc.sh) ---------------
log "5. checking host prerequisites"
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
