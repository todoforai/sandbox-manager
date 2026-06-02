#!/usr/bin/env bash
# Build & install all sandbox-manager templates into $TEMPLATES_DIR.
# Runs the same build scripts dev uses; only difference between dev and prod
# is the templates path (dev: ~/sandbox-data/templates, prod: /data/templates
# via shared/.env).
#
# Usage:
#   ./scripts/build-templates.sh                 # build both: ubuntu-base + cli-lite
#   ./scripts/build-templates.sh ubuntu          # only ubuntu-base (rootfs + kernel)
#   ./scripts/build-templates.sh cli             # only cli-lite
#   ./scripts/build-templates.sh ubuntu --force  # force rebuild even if vmlinux is fresh
#
# Side effects:
#   $TEMPLATES_DIR/ubuntu-base/{rootfs.ext4,vmlinux}
#   $TEMPLATES_DIR/cli-lite/rootfs/
#
# Requirements (same as the underlying scripts):
#   ubuntu: root (chroot+apt), debootstrap, bridge binary
#   cli:    bun
#   kernel: build-essential, flex, bison, libelf-dev, libssl-dev, bc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path resolution mirrors sandbox-manager's own (src/vm/config.rs):
# explicit TEMPLATES_DIR wins; otherwise DATA_DIR/templates; otherwise dev
# default ~/sandbox-data. Lets prod's shared/.env (TEMPLATES_DIR=/data/templates)
# and dev's defaults both work without per-env branching.
if [ -n "${TEMPLATES_DIR:-}" ]; then
    DATA_DIR="${DATA_DIR:-$(dirname "$TEMPLATES_DIR")}"
else
    DATA_DIR="${DATA_DIR:-$HOME/sandbox-data}"
    TEMPLATES_DIR="$DATA_DIR/templates"
fi
export DATA_DIR TEMPLATES_DIR

TARGET="all"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        ubuntu|cli|all) TARGET="$arg" ;;
        *) echo "usage: $0 [ubuntu|cli|all] [--force]" >&2; exit 2 ;;
    esac
done

# Bridge binary preflight — fail clearly before slow apt/debootstrap work.
# build-ubuntu-rootfs.sh needs $BRIDGE_BIN, a vendored binary (standalone
# clone), or a sibling ../bridge checkout to `make static`. Skip for cli-only.
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
VENDOR_BRIDGE="$(dirname "$SCRIPT_DIR")/vendor/todoforai-bridge-static"
if [ "$TARGET" != "cli" ] \
   && [ ! -x "${BRIDGE_BIN:-/nonexistent}" ] \
   && [ ! -e "$VENDOR_BRIDGE" ] \
   && [ ! -d "$REPO_ROOT/bridge" ]; then
    echo "ERROR: ubuntu-base needs todoforai-bridge-static." >&2
    echo "  Set BRIDGE_BIN=/path/to/binary, run scripts/sync-vendor.sh in the" >&2
    echo "  monorepo and commit vendor/, or check out $REPO_ROOT/bridge." >&2
    exit 1
fi

# One TMP for the whole run, cleaned up on exit (success or fail).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# When building inside the monorepo, refresh vendor/ from the source-of-truth
# (tool_catalog.json + bridge binary) so the committed vendor copies — which
# the standalone prod clone relies on — never drift. No-op in a standalone
# clone (no monorepo source to sync from).
if [ -f "$REPO_ROOT/packages/shared-fbe/src/tool_catalog.json" ]; then
    echo "==> refreshing vendor/ from monorepo source"
    "$SCRIPT_DIR/sync-vendor.sh"
fi

build_ubuntu() {
    local out_dir="$TEMPLATES_DIR/ubuntu-base"
    mkdir -p "$out_dir"

    echo "==> building ubuntu-base rootfs into $out_dir/rootfs.ext4"
    OUTPUT="$TMP/rootfs.ext4" "$SCRIPT_DIR/build-ubuntu-rootfs.sh"
    mv "$TMP/rootfs.ext4" "$out_dir/rootfs.ext4"

    # Stamp vmlinux with the sha256 of build-kernel.sh so we rebuild whenever
    # the kernel config recipe changes (the old `[ -f vmlinux ]` skip silently
    # shipped stale binaries across config changes — see commit bb4b8ed).
    local kbuild_hash stamp_file
    kbuild_hash=$(sha256sum "$SCRIPT_DIR/build-kernel.sh" | awk '{print $1}')
    stamp_file="$out_dir/vmlinux.kbuild-sha256"
    if [ "$FORCE" -eq 0 ] && [ -f "$out_dir/vmlinux" ] \
       && [ "$(cat "$stamp_file" 2>/dev/null || true)" = "$kbuild_hash" ]; then
        echo "==> vmlinux up to date (build-kernel.sh sha256 matches), skipping kernel build"
        return
    fi
    echo "==> building kernel into $out_dir/vmlinux"
    ( cd "$TMP" && OUTPUT="$out_dir/vmlinux" "$SCRIPT_DIR/build-kernel.sh" )
    echo "$kbuild_hash" > "$stamp_file"

    # Kernel/init boot smoke test — catches the bugs that broke "Add hosted
    # desktop" for weeks (missing CONFIG_BLOCK / CONFIG_FUTEX /
    # CONFIG_POSIX_TIMERS / MEMBARRIER / RSEQ, dropped mmds_get helper,
    # MMDS round-trip). Runs Firecracker directly — no sandbox-manager or
    # backend needed. ~10s, no host network. Skip with SKIP_SMOKE=1.
    # (smoke-test-boot.sh is the e2e variant that needs sandbox-manager.)
    if [ "${SKIP_SMOKE:-0}" != 1 ] && [ -r /dev/kvm ] && command -v firecracker >/dev/null; then
        echo "==> running kernel/init boot smoke test"
        KERNEL="$out_dir/vmlinux" ROOTFS="$out_dir/rootfs.ext4" \
            "$SCRIPT_DIR/smoke-test-kernel-boot.sh"
    else
        echo "==> skipping boot smoke test (no /dev/kvm or no firecracker; SKIP_SMOKE=${SKIP_SMOKE:-0})"
    fi
}

build_cli() {
    echo "==> building cli-lite (writes to $TEMPLATES_DIR/cli-lite)"
    # build-cli-lite.sh keys off DATA_DIR; we've ensured DATA_DIR is set above.
    "$SCRIPT_DIR/build-cli-lite.sh"
}

case "$TARGET" in
    ubuntu)  build_ubuntu ;;
    cli)     build_cli ;;
    all)     build_ubuntu; build_cli ;;
esac

echo
echo "==> Templates in $TEMPLATES_DIR:"
ls -la "$TEMPLATES_DIR"
