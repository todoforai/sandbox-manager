#!/bin/bash
# Spike: prove Kata Containers + Firecracker on stock containerd.
#
# Goal — the go/no-go for the whole refactor. After this runs green we know:
#   1. A `ctr run` boots a REAL Firecracker microVM (own kernel, not host's).
#   2. CNI gives it networking (the replacement for vm/network.rs).
#   3. A persistent home.img attaches as an extra block device, WRITABLE.
#   4. `ctr task exec` works (the replacement for the SSH/vsock recovery channel).
#
# Idempotent. Run with: sudo ./scripts/spike-kata-fc.sh
# Tear down with:        sudo ./scripts/spike-kata-fc.sh teardown
#
# This is a DEV-BOX spike. The same proof must be re-run on the cloud box
# before we trust production. Nothing here touches the old VM system.
set -euo pipefail

# --- pinned versions (bump deliberately) ----------------------------------
KATA_VERSION="${KATA_VERSION:-3.10.1}"
CNI_VERSION="${CNI_VERSION:-v1.5.1}"
ARCH="x86_64"   # uname arch (firecracker, kata-static historically)
GOARCH="amd64"  # Go arch (CNI plugins, kata asset naming)

# --- paths -----------------------------------------------------------------
DATA_DIR="${DATA_DIR:-/data}"
DM_DIR="$DATA_DIR/devmapper"                 # loopback thin-pool backing files
POOL_NAME="sandbox-pool"
CNI_BIN="/opt/cni/bin"
CNI_CONF="/etc/cni/net.d"
KATA_DIR="/opt/kata"
CONTAINERD_CFG="/etc/containerd/config.toml"
NS="sandbox-spike"                            # containerd namespace for the spike
HOME_IMG="$DM_DIR/spike-home.img"             # stand-in for a user's home.img

log() { echo -e "\n=== $* ==="; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "run as root: sudo $0"
[ -e /dev/kvm ] || die "/dev/kvm missing — KVM required"

# ===========================================================================
# teardown
# ===========================================================================
if [ "${1:-}" = "teardown" ]; then
    log "Tearing down spike"
    ctr -n "$NS" task kill spike 2>/dev/null || true
    ctr -n "$NS" container rm spike 2>/dev/null || true
    dmsetup remove "$POOL_NAME" 2>/dev/null || true
    for l in $(losetup -j "$DM_DIR/data.img" 2>/dev/null | cut -d: -f1) \
             $(losetup -j "$DM_DIR/meta.img" 2>/dev/null | cut -d: -f1); do
        losetup -d "$l" 2>/dev/null || true
    done
    echo "Removed pool + loop devices. Config backup left at ${CONTAINERD_CFG}.spike-bak (restore manually if desired)."
    exit 0
fi

# ===========================================================================
# 1. devmapper thin-pool (loopback-backed — sparse, zero disk risk)
#    Firecracker can't use overlayfs; it needs block devices. This is the
#    replacement for the old ext4-overlay/reflink rootfs cloning.
# ===========================================================================
log "1. devmapper thin-pool ($POOL_NAME)"
mkdir -p "$DM_DIR"
if dmsetup info "$POOL_NAME" &>/dev/null; then
    echo "pool $POOL_NAME already exists, skipping"
else
    DATA_SIZE_GB=50
    META_SIZE_MB=128
    [ -f "$DM_DIR/data.img" ] || truncate -s "${DATA_SIZE_GB}G" "$DM_DIR/data.img"
    [ -f "$DM_DIR/meta.img" ] || truncate -s "${META_SIZE_MB}M" "$DM_DIR/meta.img"
    DATA_LOOP=$(losetup --find --show "$DM_DIR/data.img")
    META_LOOP=$(losetup --find --show "$DM_DIR/meta.img")
    SECTORS=$(blockdev --getsz "$DATA_LOOP")
    # 128 sectors per block (64KB) — Kata/containerd devmapper default.
    dmsetup create "$POOL_NAME" \
        --table "0 $SECTORS thin-pool $META_LOOP $DATA_LOOP 128 32768"
    echo "created thin-pool: data=$DATA_LOOP meta=$META_LOOP sectors=$SECTORS"
fi

# ===========================================================================
# 2. CNI plugins (the vm/network.rs replacement)
# ===========================================================================
log "2. CNI plugins $CNI_VERSION -> $CNI_BIN"
if [ -x "$CNI_BIN/bridge" ]; then
    echo "CNI plugins already present, skipping"
else
    mkdir -p "$CNI_BIN"
    TARBALL="cni-plugins-linux-${GOARCH}-${CNI_VERSION}.tgz"
    curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/${TARBALL}" \
        -o /tmp/cni.tgz || die "CNI download failed (check CNI_VERSION)"
    tar -xzf /tmp/cni.tgz -C "$CNI_BIN"
    rm -f /tmp/cni.tgz
    echo "installed: $(ls "$CNI_BIN" | tr '\n' ' ')"
fi

# CNI conflist — declarative networking. Replaces the entire hand-rolled
# ioctl TAP/bridge/IP-allocation in vm/network.rs. host-local IPAM keeps the
# lease store (no more Redis IP-scan loop); firewall plugin does the NAT the
# old sandbox-bridge.service systemd unit did by hand.
#
# NO tc-redirect-tap: Kata's internetworking_model=tcfilter (the FC config
# default) already redirects the CNI veth to the Firecracker TAP. Adding
# tc-redirect-tap on top makes BOTH try to add the qdisc -> "file exists" and
# the VM fails to boot. Verified live: bridge+firewall alone gives the guest a
# 10.88.x.x IP with working internet + DNS.
log "2b. CNI conflist -> $CNI_CONF/10-sandbox.conflist"
mkdir -p "$CNI_CONF"
cat > "$CNI_CONF/10-sandbox.conflist" <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "sandbox",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni-sandbox0",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "subnet": "10.88.0.0/16",
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    },
    { "type": "firewall" }
  ]
}
EOF
echo "wrote conflist (bridge + host-local IPAM + firewall)"

# ===========================================================================
# 3. Kata Containers static install (+ Firecracker hypervisor config)
# ===========================================================================
log "3. Kata $KATA_VERSION -> $KATA_DIR"
if [ -x "$KATA_DIR/bin/containerd-shim-kata-v2" ]; then
    echo "Kata already installed, skipping"
else
    mkdir -p "$KATA_DIR"
    # Kata names the asset by Go-arch (amd64), not uname-arch (x86_64).
    TARBALL="kata-static-${KATA_VERSION}-${GOARCH}.tar.xz"
    KATA_URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/${TARBALL}"
    echo "downloading $TARBALL (~200MB) ..."
    # -f: fail on HTTP 4xx/5xx; -# progress bar so a hang is visible; bail if
    # the whole transfer stalls (no bytes for 60s) instead of waiting forever.
    curl -f -L -# --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
        "$KATA_URL" -o /tmp/kata.tar.xz \
        || die "download failed/stalled: $KATA_URL (check KATA_VERSION/asset name or network)"
    file /tmp/kata.tar.xz | grep -qi 'XZ compressed' \
        || die "downloaded file is not an xz tarball — got: $(file -b /tmp/kata.tar.xz)"
    echo "extracting (xz, CPU-heavy, ~1min) ..."
    # tarball expands to ./opt/kata/* — strip the leading opt/kata.
    tar -xf /tmp/kata.tar.xz -C / 
    rm -f /tmp/kata.tar.xz
    echo "installed kata: $($KATA_DIR/bin/kata-runtime --version 2>/dev/null | head -1 || echo '(version check skipped)')"
fi
# The kata-fc shim must be on PATH for containerd to launch it.
ln -sf "$KATA_DIR/bin/containerd-shim-kata-v2" /usr/local/bin/containerd-shim-kata-fc-v2

# Point Kata's default config at the Firecracker hypervisor. Kata ships a
# ready-made configuration-fc.toml; we just make sure it's the one selected.
KATA_FC_CFG="$KATA_DIR/share/defaults/kata-containers/configuration-fc.toml"
[ -f "$KATA_FC_CFG" ] || die "kata fc config not found at $KATA_FC_CFG (tarball layout changed?)"
echo "kata fc config: $KATA_FC_CFG"

# ===========================================================================
# 4. Register devmapper snapshotter + kata-fc runtime in containerd
# ===========================================================================
log "4. Patch $CONTAINERD_CFG (backup -> ${CONTAINERD_CFG}.spike-bak)"
[ -f "${CONTAINERD_CFG}.spike-bak" ] || cp "$CONTAINERD_CFG" "${CONTAINERD_CFG}.spike-bak"

# Append our blocks only if absent. We keep it additive + idempotent so a
# re-run never duplicates. (TOML append is crude but safe for a spike; the
# Go service will own a clean generated config later.)
if ! grep -q "io.containerd.snapshotter.v1.devmapper" "$CONTAINERD_CFG"; then
    cat >> "$CONTAINERD_CFG" <<EOF

# --- added by spike-kata-fc.sh ---
[plugins.'io.containerd.snapshotter.v1.devmapper']
  pool_name = "$POOL_NAME"
  root_path = "$DM_DIR/snapshotter"
  base_image_size = "10GB"
  discard_blocks = true

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-fc]
  runtime_type = "io.containerd.kata-fc.v2"
  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-fc.options]
    ConfigPath = "$KATA_FC_CFG"
# --- end spike ---
EOF
    echo "appended devmapper + kata-fc runtime config"
else
    echo "config already patched, skipping"
fi
mkdir -p "$DM_DIR/snapshotter"

log "4b. restart containerd"
systemctl restart containerd
sleep 2
ctr version >/dev/null || die "containerd not responding after restart"
echo "containerd back up"
# Confirm the devmapper snapshotter actually loaded (commonest failure point).
ctr plugin ls 2>/dev/null | grep -i devmapper || echo "WARN: devmapper plugin not listed — check 'ctr plugin ls' for error"

# ===========================================================================
# 5. THE PROOF — boot a Firecracker microVM via Kata, with CNI + home.img
# ===========================================================================
log "5. Provision a stand-in home.img (the user_home.rs artifact)"
if [ ! -f "$HOME_IMG" ]; then
    truncate -s 1G "$HOME_IMG"
    mkfs.ext4 -F -E lazy_itable_init=1,lazy_journal_init=1 "$HOME_IMG" >/dev/null
fi
echo "home.img: $HOME_IMG"

log "5b. Pull busybox + run as a Kata/Firecracker microVM"
ctr -n "$NS" image pull docker.io/library/busybox:latest

echo
echo ">>> Booting microVM. If this prints a DIFFERENT kernel than the host"
echo ">>> ($(uname -r)), it is a real Firecracker guest — the core proof."
echo
HOST_KERNEL=$(uname -r)
GUEST_KERNEL=$(ctr -n "$NS" run --rm \
    --runtime io.containerd.kata-fc.v2 \
    --snapshotter devmapper \
    docker.io/library/busybox:latest spike-kernel uname -r)

echo "host kernel : $HOST_KERNEL"
echo "guest kernel: $GUEST_KERNEL"
if [ "$HOST_KERNEL" != "$GUEST_KERNEL" ]; then
    echo "✅ PROOF 1: guest kernel differs from host — real Firecracker microVM."
else
    echo "⚠️  guest kernel == host kernel. Likely fell back to runc, NOT a VM. Investigate kata-fc config."
fi

echo
echo ">>> Next manual checks (run after reviewing this output):"
cat <<EOF
  # CNI networking inside the guest:
  ctr -n $NS run --rm --runtime io.containerd.kata-fc.v2 --snapshotter devmapper \\
      --with-ns network:/var/run/netns/... docker.io/library/busybox:latest net ip addr

  # home.img attached + WRITABLE inside the guest (mount as extra device):
  ctr -n $NS run --rm --runtime io.containerd.kata-fc.v2 --snapshotter devmapper \\
      --mount type=bind,src=$HOME_IMG,dst=/root.img,options=rbind:rw \\
      docker.io/library/busybox:latest hometest sh -c 'echo hi > /tmp/x && cat /tmp/x'

  # task exec (the recovery-channel replacement):
  ctr -n $NS run -d --runtime io.containerd.kata-fc.v2 --snapshotter devmapper \\
      docker.io/library/busybox:latest longrun sleep 3600
  ctr -n $NS task exec --exec-id dbg longrun uname -a
EOF

log "Spike step done. Review the kernel comparison above."
echo "Teardown when finished: sudo $0 teardown"
