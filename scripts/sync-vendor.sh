#!/usr/bin/env bash
# Single entry point to sync the monorepo-only inputs the ubuntu-base rootfs
# build needs, so a STANDALONE clone of this repo (what prod deploys — see
# deploy.sh) can build templates without the monorepo present. Two inputs,
# each from its correct source:
#
#   - tool_catalog.json  — the tfa-* tool list. Copied from the monorepo
#     (packages/shared-fbe/src/tool_catalog.json) into vendor/tool_catalog.json
#     and committed. Small text data, no publish pipeline; same vendor-with-sync
#     pattern as packages/shared-web/sync.sh.
#   - bridge binary       — NOT committed. Fetched + checksum-verified from its
#     canonical GitHub release (the linux-x64 asset is the static-musl build),
#     pinned in vendor/bridge.tag. Cached under vendor/cache/ (gitignored).
#
# Usage:
#   sync-vendor.sh                # sync both (default)
#   sync-vendor.sh catalog        # only the catalog (needs the monorepo)
#   sync-vendor.sh bridge         # only fetch the pinned bridge; prints its path
#   sync-vendor.sh --check        # exit 1 if catalog stale or bridge unfetchable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_MGR_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$SANDBOX_MGR_ROOT")"
VENDOR_DIR="$SANDBOX_MGR_ROOT/vendor"

CATALOG_SRC="${TOOL_CATALOG_JSON:-$REPO_ROOT/packages/shared-fbe/src/tool_catalog.json}"

# Fetch the pinned bridge release into vendor/cache/ (idempotent) and print its
# path on stdout. Resolution of the tag: BRIDGE_TAG env > vendor/bridge.tag.
bridge_fetch() {
    local tag asset cache base tmp expected actual
    tag="${BRIDGE_TAG:-$(cat "$VENDOR_DIR/bridge.tag" 2>/dev/null || true)}"
    [ -n "$tag" ] || { echo "ERROR: no bridge tag (vendor/bridge.tag or BRIDGE_TAG)" >&2; return 1; }
    asset="todoforai-bridge-linux-${BRIDGE_ARCH:-x64}"
    cache="$VENDOR_DIR/cache/${tag}-${asset}"
    if [ ! -f "$cache" ]; then
        base="https://github.com/todoforai/bridge/releases/download/$tag"
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
        curl -fsSL "$base/$asset"        -o "$tmp/bin" || { echo "ERROR: download failed: $base/$asset" >&2; return 1; }
        curl -fsSL "$base/$asset.sha256" -o "$tmp/sha" || { echo "ERROR: sha256 fetch failed" >&2; return 1; }
        expected="$(awk '{print $1}' "$tmp/sha")"
        actual="$(sha256sum "$tmp/bin" | awk '{print $1}')"
        [ "$expected" = "$actual" ] || { echo "ERROR: sha256 mismatch ($asset $tag): want $expected got $actual" >&2; return 1; }
        mkdir -p "$VENDOR_DIR/cache"; chmod 0755 "$tmp/bin"; mv "$tmp/bin" "$cache"
        echo "fetched $asset $tag (verified)" >&2
    fi
    echo "$cache"
}

catalog_sync() {
    [ -f "$CATALOG_SRC" ] || { echo "ERROR: catalog not found: $CATALOG_SRC" >&2; return 1; }
    mkdir -p "$VENDOR_DIR"
    cp -f "$CATALOG_SRC" "$VENDOR_DIR/tool_catalog.json"
    echo "✓ vendored tool_catalog.json → $VENDOR_DIR ($(du -h "$VENDOR_DIR/tool_catalog.json" | cut -f1))"
}

case "${1:-all}" in
    bridge)  bridge_fetch ;;
    catalog) catalog_sync; echo "Commit vendor/tool_catalog.json so the standalone clone is self-sufficient." ;;
    --check)
        diff -q "$CATALOG_SRC" "$VENDOR_DIR/tool_catalog.json" >/dev/null 2>&1 \
            || { echo "ERROR: vendor/tool_catalog.json is stale — run scripts/sync-vendor.sh and commit." >&2; exit 1; }
        bridge_fetch >/dev/null || { echo "ERROR: pinned bridge release not fetchable (vendor/bridge.tag)." >&2; exit 1; }
        echo "✓ vendor/ is in sync (catalog up to date, bridge $(cat "$VENDOR_DIR/bridge.tag") fetchable)." ;;
    all)
        catalog_sync
        bridge_fetch >/dev/null
        echo "✓ bridge $(cat "$VENDOR_DIR/bridge.tag") cached under vendor/cache/"
        echo "Commit vendor/tool_catalog.json so the standalone clone is self-sufficient." ;;
    *) echo "usage: $0 [all|catalog|bridge|--check]" >&2; exit 2 ;;
esac
