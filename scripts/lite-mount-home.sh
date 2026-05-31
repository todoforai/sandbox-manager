#!/bin/bash
# Loop-mount / unmount per-user $HOME disk images for cli-lite sandboxes.
#
# Why this exists as a separate script:
#   `mount(2)` + LOOP_SET_FD require CAP_SYS_ADMIN. On prod sandbox-manager
#   runs as root and could call them directly, but on dev it runs as a
#   regular user. Rather than splitting the code path (file caps + group
#   `disk` + devtmpfs-permission games — see git history), we always shell
#   out to this helper via a tight sudoers rule that's a no-op when we're
#   already root.
#
# Usage:
#   lite-mount-home.sh attach <image-path> <target-dir>
#     → loop-mounts <image> at <target>, prints "/dev/loopN" on stdout.
#   lite-mount-home.sh detach <target-dir>
#     → unmounts <target>, detaches the backing loop device.
#
# Path validation: both arguments must be absolute and contain no `..`.
# The caller (sandbox-manager) is trusted to pass paths within its data
# dir; we don't reach further than that — we won't, e.g., mount over /.
set -euo pipefail

die() { echo "lite-mount-home: $*" >&2; exit 64; }

validate_abs_no_traversal() {
    case "$1" in
        /*) ;;
        *) die "path not absolute: $1" ;;
    esac
    case "$1" in
        *..*) die "path contains '..': $1" ;;
    esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
    attach)
        [ "$#" -eq 2 ] || die "usage: attach <image> <target>"
        IMG="$1"; TARGET="$2"
        validate_abs_no_traversal "$IMG"
        validate_abs_no_traversal "$TARGET"
        [ -f "$IMG" ]  || die "image missing: $IMG"
        [ -d "$TARGET" ] || die "target dir missing: $TARGET"

        # losetup -f --show: allocate next free /dev/loopN, attach IMG,
        # print device path. Atomic — no GET_FREE/SET_FD race window.
        LOOP="$(losetup -f --show -- "$IMG")"
        # On mount failure, detach the loop we just allocated.
        if ! mount -t ext4 -- "$LOOP" "$TARGET"; then
            losetup -d -- "$LOOP" || true
            die "mount $LOOP $TARGET failed"
        fi
        echo "$LOOP"
        ;;

    detach)
        [ "$#" -eq 1 ] || die "usage: detach <target>"
        TARGET="$1"
        validate_abs_no_traversal "$TARGET"

        # Look up which loop backs the mount BEFORE unmounting, so the
        # losetup -d below knows what to free even after umount drops the
        # mount entry. `findmnt -n -o SOURCE` prints e.g. `/dev/loop17`.
        LOOP="$(findmnt -n -o SOURCE -- "$TARGET" 2>/dev/null || true)"

        # Resolve the backing image so we can also free parallel loop
        # attachments (e.g. udisks2 auto-mount on desktop hosts allocates
        # its own /dev/loopN against the same file — our umount won't
        # touch that one, so without this sweep loops leak per cycle).
        IMG=""
        if [ -n "$LOOP" ] && [ -b "$LOOP" ]; then
            IMG="$(losetup -n -O BACK-FILE -- "$LOOP" 2>/dev/null || true)"
        fi

        if mountpoint -q -- "$TARGET"; then
            umount -- "$TARGET" || die "umount $TARGET failed"
        fi

        # Free every loop attached to this backing file. Any parallel
        # mount (e.g. /media/<user>/<uuid> from udisks2) is unmounted
        # first. Idempotent — missing entries are fine.
        if [ -n "$IMG" ]; then
            while IFS= read -r L; do
                [ -n "$L" ] && [ -b "$L" ] || continue
                MNT="$(findmnt -n -o TARGET -- "$L" 2>/dev/null || true)"
                if [ -n "$MNT" ]; then
                    umount -- "$MNT" 2>/dev/null || true
                fi
                losetup -d -- "$L" 2>/dev/null || true
            done < <(losetup -j "$IMG" -n -O NAME 2>/dev/null)
        elif [ -n "$LOOP" ] && [ -b "$LOOP" ]; then
            losetup -d -- "$LOOP" 2>/dev/null || true
        fi
        ;;

    *)
        die "usage: $0 {attach <image> <target> | detach <target>}"
        ;;
esac
