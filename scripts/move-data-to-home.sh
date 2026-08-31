#!/usr/bin/env bash
# Move /data (devmapper thin pool + per-user home images) off the 92G root
# filesystem onto /home, WITHOUT touching any code or config: /data stays the
# path everything references, it just becomes a bind mount of $DST.
#
# Why: /data/devmapper/data.img declares a 1000G thin pool but lives as a sparse
# file on the 92G root fs, so the real ceiling is ~92G. sandbox-manager refuses
# to provision at >=90% used (maxDiskPercent, internal/service/service.go), which
# is what blocked cloud VM provisioning.
#
# The teardown order is the whole point of this script. containerd — not
# sandbox-manager — owns the VMs and the devmapper pool, and Docker shares that
# same containerd. The pool has live per-VM snapshot children, so it cannot be
# removed until every task is gone. Order: tasks -> docker -> containerd ->
# pool service -> dm children -> pool -> loops. Restore is the exact reverse,
# reusing the existing sandbox-pool-up.sh (the boot-time restore path).
#
# Copies with `cp -a --sparse=always`: data.img is 1000G logical but ~4G
# allocated, and cp uses the filesystem's hole map directly.
#
# Idempotent-ish: refuses to start if a previous run left state behind.
# Rollback at any point:  rm the /data line from /etc/fstab, umount /data,
#                         rmdir /data && mv /data.old /data, then
#                         systemctl start sandbox-pool containerd docker
#
# Run as: sudo bash move-data-to-home.sh
set -euo pipefail

SRC=/data
DST=/home/sandbox-data-root
POOL=sandbox-pool
NS="${CONTAINERD_NAMESPACE:-default}"
PM2=/home/hm/.nvm/versions/node/v24.13.0/bin/pm2
REPO=/home/hm/repo/todoforai/sandbox-manager

log()  { echo -e "\n=== $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "run with sudo"

# ---------------------------------------------------------------- preflight
log "preflight"
[ -x "$PM2" ] || die "pm2 not found at $PM2"
[ -d "$SRC" ] || die "$SRC missing"
mountpoint -q "$SRC" && die "$SRC is already a mount point — migration already done?"
[ -e "$DST" ] && die "$DST already exists — remove it or resume manually"
[ -e "${SRC}.old" ] && die "${SRC}.old exists from a previous run — clean it up first"
grep -q "[[:space:]]$SRC[[:space:]]" /etc/fstab && die "/etc/fstab already has a $SRC entry"

src_used=$(du -sx --block-size=1G "$SRC" | cut -f1)
dst_free=$(df --output=avail --block-size=1G /home | tail -1 | tr -d ' ')
[ "$dst_free" -gt $((src_used * 2)) ] || die "not enough space on /home (${dst_free}G free, need >$((src_used*2))G)"
echo "  $SRC uses ${src_used}G, /home has ${dst_free}G free"

cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
echo "  saved /etc/fstab backup"
log "state before (keep this output for rollback)"
losetup -a | grep "$SRC" || true
dmsetup ls --tree || true

# ------------------------------------------------------------ stop the stack
log "1/8 stopping sandbox-manager (no new provisioning)"
sudo -u hm "$PM2" stop sandbox-manager sandbox-manager-web

log "2/8 deleting sandbox tasks via containerd (graceful — frees dm snapshots)"
# Delete through containerd so the shim, netns, snapshot child and home loop
# are released the same way internal/vm/manager.go does it. Killing firecracker
# directly would orphan all of that and wedge the pool removal below.
for c in $(ctr -n "$NS" containers list -q 2>/dev/null); do
    echo "  container $c"
    ctr -n "$NS" tasks kill -s SIGKILL "$c" 2>/dev/null || true
    ctr -n "$NS" tasks delete --force "$c" 2>/dev/null || true
    ctr -n "$NS" containers delete "$c" 2>/dev/null || true
done

# Its container/task is gone by now, so a leftover firecracker is an orphan the
# shim failed to reap — safe to kill directly (this is what manager.go's
# forceKill fallback does too).
for i in $(seq 20); do
    pgrep -f '^/firecracker' >/dev/null || break
    sleep 1
done
if pgrep -f '^/firecracker' >/dev/null; then
    echo "  orphaned firecracker after container delete, killing"
    pkill -9 -f '^/firecracker' || true
    sleep 2
fi
pgrep -f '^/firecracker' >/dev/null && die "firecracker will not die — investigate before continuing"

log "3/8 stopping docker (shares this containerd), then containerd"
systemctl stop docker.socket docker.service 2>/dev/null || true
systemctl stop containerd.service
# Clear the oneshot's RemainAfterExit state, else it won't re-run on restore.
systemctl stop sandbox-pool.service 2>/dev/null || true
sleep 2

log "4/8 releasing device-mapper devices"
# Children (per-VM thin volumes) must go before the parent pool.
for d in $(dmsetup ls 2>/dev/null | awk '/^sandbox-pool-snap/ {print $1}'); do
    echo "  removing child $d"
    dmsetup remove "$d"
done
dmsetup info "$POOL" &>/dev/null && { echo "  removing $POOL"; dmsetup remove "$POOL"; }
dmsetup info "$POOL" &>/dev/null && die "$POOL still present — do NOT continue, something holds it"

log "5/8 detaching loop devices backed by $SRC"
for l in $(losetup -a | grep "$SRC" | cut -d: -f1); do
    echo "  detaching $l"
    losetup -d "$l" || die "$l is busy — stop whatever holds it and rerun"
done
losetup -a | grep -q "$SRC" && die "loop devices still attached to $SRC"
sync

# --------------------------------------------------------------------- copy
log "6/8 copying $SRC -> $DST (sparse-aware; ~${src_used}G actual)"
mkdir -p "$DST"
cp -a --sparse=always "$SRC/." "$DST/"
sync

log "verifying copy"
for f in devmapper/data.img devmapper/meta.img; do
    a=$(stat -c%s "$SRC/$f"); b=$(stat -c%s "$DST/$f")
    [ "$a" = "$b" ] || die "$f size mismatch: $a vs $b"
    echo "  $f logical=$a allocated=$(du -h "$DST/$f" | cut -f1) OK"
done
sa=$(find "$SRC" | wc -l); sb=$(find "$DST" | wc -l)
[ "$sa" = "$sb" ] || die "file count mismatch: $sa vs $sb"
echo "  $sa entries copied"
dst_alloc=$(du -sh "$DST" | cut -f1)
echo "  $DST allocated: $dst_alloc (must NOT be ~1TB)"

# ------------------------------------------------------------- switch paths
log "7/8 switching $SRC to a bind mount of $DST"
mv "$SRC" "${SRC}.old"
mkdir -p "$SRC"
mount --bind "$DST" "$SRC"
[ -f "$SRC/devmapper/data.img" ] || { umount "$SRC"; rmdir "$SRC"; mv "${SRC}.old" "$SRC"; die "bind mount looks wrong, rolled back"; }
findmnt "$SRC"
df -h "$SRC" | tail -1

# Persist only after the live bind mount is proven good.
echo "$DST $SRC none bind 0 0" >> /etc/fstab
findmnt --verify || die "fstab verify failed — remove the $SRC line before rebooting"

# ------------------------------------------------------------------ restore
log "8/8 restoring the stack"
"$REPO/scripts/sandbox-pool-up.sh"
dmsetup info "$POOL" &>/dev/null || die "pool not restored"
systemctl start containerd.service
sleep 3
ctr plugin ls 2>/dev/null | grep devmapper || echo "  (check devmapper plugin manually)"
systemctl start docker.service
sudo -u hm "$PM2" start sandbox-manager sandbox-manager-web

log "done"
findmnt "$SRC"
df -h "$SRC" | tail -1
losetup -a | grep "$SRC" || true
dmsetup ls --tree || true
cat <<EOF

Next: provision a cloud VM from the UI and confirm it boots and its home.img
attaches from $SRC/user-homes/.

Keep ${SRC}.old until that works AND you have rebooted once. Then:
  sudo rm -rf ${SRC}.old

Rollback (if something is wrong):
  sudo sed -i '\\#^$DST $SRC #d' /etc/fstab
  sudo systemctl stop docker containerd
  sudo umount $SRC && sudo rmdir $SRC && sudo mv ${SRC}.old $SRC
  sudo $REPO/scripts/sandbox-pool-up.sh
  sudo systemctl start containerd docker
EOF
