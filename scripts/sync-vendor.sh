#!/usr/bin/env bash
# Sync the monorepo-only inputs that the ubuntu-base rootfs build needs into
# sandbox-manager/vendor/, so a STANDALONE clone of this repo (what prod
# deploys — see deploy.sh) can build templates without the monorepo present.
#
# Source of truth stays in the monorepo; this just copies the two small,
# self-contained artifacts the standalone clone can't otherwise reach:
#   - tool_catalog.json            (packages/shared-fbe/src/) — the tfa-* list
#   - todoforai-bridge-static      (bridge/build/)            — PTY relay binary
#
# Run from the monorepo before pushing sandbox-manager to its own GitHub repo
# (tfa-push wires this in). Commit the refreshed vendor/ so it ships with the
# clone. Idempotent; re-run any time the catalog or bridge changes.
#
# Usage:
#   sandbox-manager/scripts/sync-vendor.sh          # copy from monorepo source
#   sandbox-manager/scripts/sync-vendor.sh --check  # exit 1 if vendor is stale
#                                                   # (for CI / pre-push guards)
set -euo pipefail

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_MGR_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$SANDBOX_MGR_ROOT")"
VENDOR_DIR="$SANDBOX_MGR_ROOT/vendor"

CATALOG_SRC="${TOOL_CATALOG_JSON:-$REPO_ROOT/packages/shared-fbe/src/tool_catalog.json}"
BRIDGE_SRC="${BRIDGE_BIN:-$REPO_ROOT/bridge/build/todoforai-bridge-static}"

[ -f "$CATALOG_SRC" ] || { echo "ERROR: catalog not found: $CATALOG_SRC" >&2; exit 1; }
if [ ! -f "$BRIDGE_SRC" ]; then
    [ "$CHECK" = 1 ] && { echo "ERROR: bridge binary missing: $BRIDGE_SRC" >&2; exit 1; }
    echo "bridge binary missing at $BRIDGE_SRC — building (make static)..."
    ( cd "$REPO_ROOT/bridge" && make static )
fi

if [ "$CHECK" = 1 ]; then
    stale=0
    diff -q "$CATALOG_SRC" "$VENDOR_DIR/tool_catalog.json" >/dev/null 2>&1 || stale=1
    cmp -s "$BRIDGE_SRC" "$VENDOR_DIR/todoforai-bridge-static" 2>/dev/null || stale=1
    if [ "$stale" = 1 ]; then
        echo "ERROR: vendor/ is stale — run scripts/sync-vendor.sh and commit." >&2
        exit 1
    fi
    echo "✓ vendor/ is up to date with monorepo source."
    exit 0
fi

mkdir -p "$VENDOR_DIR"
cp -f "$CATALOG_SRC" "$VENDOR_DIR/tool_catalog.json"
cp -f "$BRIDGE_SRC"  "$VENDOR_DIR/todoforai-bridge-static"
chmod 0755 "$VENDOR_DIR/todoforai-bridge-static"

echo "✓ vendored → $VENDOR_DIR"
echo "    tool_catalog.json           ($(du -h "$VENDOR_DIR/tool_catalog.json" | cut -f1))"
echo "    todoforai-bridge-static     ($(du -h "$VENDOR_DIR/todoforai-bridge-static" | cut -f1))"
echo "Commit vendor/ so the standalone sandbox-manager clone is self-sufficient."
