#!/usr/bin/env bash
# Nightly off-host backup of every per-user home.img (the cloud VMs' /root and
# /home, the only persistent data in a VM).
#
# 1. Mirror: changed home.img files are copied (sparse) into $MIRROR. For a
#    running VM the guest's /root is fsfrozen during the copy (seconds), so
#    the copy is consistent. Unchanged files keep their inode.
# 2. restic backs up the whole mirror (unchanged files are skipped by
#    metadata; the images are sparse, their zero runs dedupe to one chunk),
#    one snapshot per night, then applies retention.
# Restore one user: restic restore latest --include /<userId>.img --target /tmp/r
#
# Config: /etc/default/home-backup (RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE,
# optional RESTIC_* env). Without it this is a no-op, so deploy can always
# install the timer. Installed by deploy.sh as home-backup.{service,timer}.
set -euo pipefail

CONF=/etc/default/home-backup
[ -r "$CONF" ] || { echo "home-backup: $CONF missing, not configured"; exit 0; }
set -a; . "$CONF"; set +a

HOMES=${USER_HOMES_DIR:-/data/user-homes}
MIRROR=${MIRROR_DIR:-/data/home-backup-mirror}
NS=${CONTAINERD_NAMESPACE:-sandbox}
mkdir -p "$MIRROR"

# userId -> running container, to freeze its /root while copying.
declare -A vm
while read -r c; do
    u=$(ctr -n "$NS" c info "$c" 2>/dev/null | jq -r '.Labels["todoforai.user_id"] // empty') || continue
    [ -n "$u" ] && vm[$u]=$c
done < <(ctr -n "$NS" t ls | awk 'NR>1 && $3=="RUNNING" {print $1}')

guest() { timeout 20 ctr -n "$NS" t exec --exec-id "bk$RANDOM$RANDOM" "$1" fsfreeze "$2" /root; }

copied=0 failed=0
for img in "$HOMES"/*/home.img; do
    u=$(basename "$(dirname "$img")")
    dst=$MIRROR/$u.img
    [ -e "$dst" ] && [ ! "$img" -nt "$dst" ] && continue   # unchanged since last mirror
    c=${vm[$u]:-}
    frozen=
    if [ -n "$c" ] && guest "$c" -f 2>/dev/null; then frozen=1; fi
    if cp --sparse=always --preserve=timestamps "$img" "$dst.tmp"; then mv "$dst.tmp" "$dst"; copied=$((copied+1))
    else rm -f "$dst.tmp"; failed=$((failed+1)); echo "home-backup: copy failed: $u" >&2; fi
    # Always thaw; retry once so a VM is never left frozen.
    [ -n "$frozen" ] && { guest "$c" -u || guest "$c" -u || echo "home-backup: THAW FAILED: $u ($c)" >&2; }
done

# Users whose home was deleted drop out of the mirror (kept in older snapshots).
for m in "$MIRROR"/*.img; do
    [ -e "$m" ] || continue
    [ -e "$HOMES/$(basename "$m" .img)/home.img" ] || rm -f "$m"
done
echo "home-backup: mirrored $copied changed image(s), $failed failed"

restic cat config >/dev/null 2>&1 || restic init
nice -n 10 ionice -c3 restic backup --host sandbox --tag homes --read-concurrency 8 "$MIRROR"
restic forget --host sandbox --tag homes --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
[ "$failed" -eq 0 ]
