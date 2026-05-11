#!/usr/bin/env bash
# Build & install all sandbox-manager templates into $TEMPLATES_DIR.
# Runs the same build scripts dev uses; only difference between dev and prod
# is the templates path (dev: ~/sandbox-data/templates, prod: /data/templates
# via shared/.env).
#
# Usage:
#   ./scripts/build-templates.sh           # build both: ubuntu-base + cli-lite
#   ./scripts/build-templates.sh ubuntu    # only ubuntu-base (rootfs + kernel)
#   ./scripts/build-templates.sh cli       # only cli-lite
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
TARGET="${1:-all}"

# Bridge binary preflight — fail clearly before slow apt/debootstrap work.
# build-ubuntu-rootfs.sh needs $BRIDGE_BIN (or a sibling ../bridge checkout
# to `make static`). Skip the check for cli-only builds.
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
if [ "$TARGET" != "cli" ] \
   && [ ! -x "${BRIDGE_BIN:-/nonexistent}" ] \
   && [ ! -d "$REPO_ROOT/bridge" ]; then
    echo "ERROR: ubuntu-base needs todoforai-bridge-static." >&2
    echo "  Set BRIDGE_BIN=/path/to/binary, or check out $REPO_ROOT/bridge." >&2
    exit 1
fi

# One TMP for the whole run, cleaned up on exit (success or fail).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

build_ubuntu() {
    local out_dir="$TEMPLATES_DIR/ubuntu-base"
    mkdir -p "$out_dir"

    echo "==> building ubuntu-base rootfs into $out_dir/rootfs.ext4"
    OUTPUT="$TMP/rootfs.ext4" "$SCRIPT_DIR/build-ubuntu-rootfs.sh"
    mv "$TMP/rootfs.ext4" "$out_dir/rootfs.ext4"

    if [ -f "$out_dir/vmlinux" ]; then
        echo "==> vmlinux already present, skipping kernel build (delete to force rebuild)"
        return
    fi
    echo "==> building kernel into $out_dir/vmlinux"
    ( cd "$TMP" && OUTPUT="$out_dir/vmlinux" "$SCRIPT_DIR/build-kernel.sh" )
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
    *) echo "usage: $0 [ubuntu|cli|all]" >&2; exit 2 ;;
esac

echo
echo "==> Templates in $TEMPLATES_DIR:"
ls -la "$TEMPLATES_DIR"
