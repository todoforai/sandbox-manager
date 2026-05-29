#!/usr/bin/env bash
# Boot smoke test: spawn one VM from the installed ubuntu-base template,
# read the console log, fail loudly on any of the three classes of bugs
# we ate in May 2026:
#
#   1. Kernel can't mount rootfs (virtio block / virtio_mmio_cmdline_devices)
#   2. Userspace can't syscall (futex / posix_timers / membarrier / rseq)
#   3. Bridge can't reach api.todofor.ai (UFW FORWARD policy DROP)
#
# Designed to run on the prod host (or any sandbox-manager box) after
# `./deploy.sh provision-templates`. CI uses this gate to refuse a deploy
# whose template was built broken.
#
# Exits non-zero on failure. Cleans up the VM either way.

set -euo pipefail

# SANDBOX_MANAGER_ADMIN_KEY guards the loopback admin socket (default
# 127.0.0.1:8210). Create still goes through public POST /sandbox with
# a normal Bearer; the admin key is only needed to DELETE in cleanup if
# we want to skip the public-auth dance.
ADMIN_KEY="${SANDBOX_MANAGER_ADMIN_KEY:-$(grep -oE '^SANDBOX_MANAGER_ADMIN_KEY=\S+' /etc/sandbox-manager.env 2>/dev/null | cut -d= -f2)}"
BEARER="${BEARER:-$ADMIN_KEY}"  # admin bearer doubles as public-route auth
MANAGER_URL="${MANAGER_URL:-http://127.0.0.1:7700}"
ADMIN_URL="${ADMIN_URL:-http://127.0.0.1:8210}"
USER_ID="${USER_ID:-00000000-0000-0000-0000-000000000000}"
TEMPLATE="${TEMPLATE:-ubuntu-base}"
SIZE="${SIZE:-medium}"
TIMEOUT="${TIMEOUT:-90}"

if [ -z "$BEARER" ]; then
    echo "[smoke] need BEARER or SANDBOX_MANAGER_ADMIN_KEY set" >&2
    exit 2
fi

cleanup() {
    [ -z "${SID:-}" ] && return 0
    curl -sS -X DELETE -H "Authorization: Bearer $ADMIN_KEY" \
         "$ADMIN_URL/admin/api/sandbox/$SID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[smoke] creating $TEMPLATE/$SIZE VM..."
SID=$(curl -fsS -X POST -H "Authorization: Bearer $BEARER" -H 'Content-Type: application/json' \
      -d "{\"template\":\"$TEMPLATE\",\"size\":\"$SIZE\",\"user_id\":\"$USER_ID\"}" \
      "$MANAGER_URL/sandbox" | jq -r .id)
[ -n "$SID" ] && [ "$SID" != "null" ] || { echo "[smoke] FAIL: create returned no id"; exit 1; }
echo "[smoke] sandbox_id=$SID"

CONSOLE=/data/overlays/runtime/$SID.console.log

# Wait for console to start writing
for _ in $(seq 1 30); do [ -s "$CONSOLE" ] && break; sleep 1; done
[ -s "$CONSOLE" ] || { echo "[smoke] FAIL: console log never appeared at $CONSOLE" >&2; exit 1; }

# Watch console for up to TIMEOUT seconds for either success or any
# of the known failure signatures.
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if grep -qE 'Kernel panic|VFS: Unable to mount|VFS: Cannot open root' "$CONSOLE"; then
        echo "[smoke] FAIL(kernel-boot): rootfs not mounted — VIRTIO_BLK / VIRTIO_MMIO_CMDLINE_DEVICES?" >&2
        tail -40 "$CONSOLE" >&2; exit 1
    fi
    if grep -qE 'futex facility returned|POSIX timer syscall while|membarrier.*ENOSYS' "$CONSOLE"; then
        echo "[smoke] FAIL(userspace-syscall): missing FUTEX / POSIX_TIMERS / MEMBARRIER in guest kernel" >&2
        tail -40 "$CONSOLE" >&2; exit 1
    fi
    if grep -qE 'MMDS PUT failed|mmds_get.*rc=' "$CONSOLE"; then
        echo "[smoke] WARN(mmds): GET/PUT failure logged — investigate" >&2
        tail -40 "$CONSOLE" >&2
    fi
    # Success: bridge enrolled and authenticated
    if grep -qE '✓ Authenticated|✓ Enrolled' "$CONSOLE"; then
        echo "[smoke] PASS: bridge enrolled and authenticated"
        exit 0
    fi
    sleep 2
done

echo "[smoke] FAIL(timeout): no success marker after ${TIMEOUT}s — likely bridge can't reach api.todofor.ai (UFW FORWARD?)" >&2
tail -60 "$CONSOLE" >&2
exit 1
