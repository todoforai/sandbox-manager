#!/usr/bin/env bash
# Restore the loopback-backed devmapper thin-pool at boot, BEFORE containerd.
#
# The thin-pool backing files (data.img/meta.img) persist on disk across
# reboots, but the kernel state that makes them a usable pool does NOT:
#   - losetup attachments (/dev/loopN -> *.img) are kernel-memory only
#   - the `dmsetup create` thin-pool target is an in-kernel device-mapper map
# Both vanish on reboot, so containerd's devmapper snapshotter fails to load
# ("snapshotter not loaded: devmapper: invalid argument") and the first
# createSandbox 500s. This re-attaches the loops + recreates the dm target so
# the pool is present before containerd starts its devmapper plugin.
#
# Idempotent: no-op if the pool already exists. NEVER creates backing files —
# if they're missing the pool was never provisioned, so we bail and point at
# spike-kata-fc.sh (creating empty .img here would silently wipe every VM).
#
# Installed as a systemd oneshot ordered Before=containerd.service by
# setup-host.sh. Manual run: sudo ./scripts/sandbox-pool-up.sh
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
DM_DIR="$DATA_DIR/devmapper"
POOL_NAME="${POOL_NAME:-sandbox-pool}"
DATA_IMG="$DM_DIR/data.img"
META_IMG="$DM_DIR/meta.img"

log() { echo "sandbox-pool-up: $*"; }
die() { echo "sandbox-pool-up: ERROR: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "run as root"

if dmsetup info "$POOL_NAME" &>/dev/null; then
    log "pool '$POOL_NAME' already present, nothing to do"
    exit 0
fi

[ -f "$DATA_IMG" ] || die "$DATA_IMG missing — pool was never provisioned, run scripts/spike-kata-fc.sh"
[ -f "$META_IMG" ] || die "$META_IMG missing — pool was never provisioned, run scripts/spike-kata-fc.sh"

# Reuse an existing loop attachment if the .img is already bound, else attach.
attach() {
    local img="$1" existing
    existing="$(losetup -j "$img" 2>/dev/null | cut -d: -f1 | head -n1)"
    if [ -n "$existing" ]; then echo "$existing"; else losetup --find --show "$img"; fi
}

DATA_LOOP="$(attach "$DATA_IMG")"
META_LOOP="$(attach "$META_IMG")"
SECTORS="$(blockdev --getsz "$DATA_LOOP")"

# 128 sectors per block (64KB) — must match spike-kata-fc.sh exactly, or the
# existing thin volumes on data.img won't line up.
dmsetup create "$POOL_NAME" \
    --table "0 $SECTORS thin-pool $META_LOOP $DATA_LOOP 128 32768"

log "restored pool '$POOL_NAME': data=$DATA_LOOP meta=$META_LOOP sectors=$SECTORS"
