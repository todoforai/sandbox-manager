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
#   - rclone binary       — same pattern, pinned in assets/rclone.tag +
#     assets/rclone.sha256. Backs the guest's cloud FUSE mount AND the
#     frontend's "connect a data source" UI.
#
# Usage:
#   sync-vendor.sh                # sync all (default)
#   sync-vendor.sh catalog        # only the catalog (needs the monorepo)
#   sync-vendor.sh bridge         # only fetch the pinned bridge; prints its path
#   sync-vendor.sh rclone         # only fetch the pinned rclone; prints its path
#   sync-vendor.sh --check        # exit 1 if catalog stale or a binary unfetchable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_MGR_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$SANDBOX_MGR_ROOT")"
ASSETS_DIR="$SANDBOX_MGR_ROOT/assets"

CATALOG_SRC="${TOOL_CATALOG_JSON:-$REPO_ROOT/packages/shared-fbe/src/tool_catalog.json}"

# Fetch the pinned bridge release into vendor/cache/ (idempotent) and print its
# path on stdout. Resolution of the tag: BRIDGE_TAG env > vendor/bridge.tag.
bridge_fetch() {
    local tag asset cache base tmp expected actual
    tag="${BRIDGE_TAG:-$(cat "$ASSETS_DIR/bridge.tag" 2>/dev/null || true)}"
    [ -n "$tag" ] || { echo "ERROR: no bridge tag (vendor/bridge.tag or BRIDGE_TAG)" >&2; return 1; }
    asset="todoforai-bridge-linux-${BRIDGE_ARCH:-x64}"
    cache="$ASSETS_DIR/cache/${tag}-${asset}"
    if [ ! -f "$cache" ]; then
        base="https://github.com/todoforai/bridge/releases/download/$tag"
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
        curl -fsSL "$base/$asset"        -o "$tmp/bin" || { echo "ERROR: download failed: $base/$asset" >&2; return 1; }
        curl -fsSL "$base/$asset.sha256" -o "$tmp/sha" || { echo "ERROR: sha256 fetch failed" >&2; return 1; }
        expected="$(awk '{print $1}' "$tmp/sha")"
        actual="$(sha256sum "$tmp/bin" | awk '{print $1}')"
        [ "$expected" = "$actual" ] || { echo "ERROR: sha256 mismatch ($asset $tag): want $expected got $actual" >&2; return 1; }
        mkdir -p "$ASSETS_DIR/cache"; chmod 0755 "$tmp/bin"; mv "$tmp/bin" "$cache"
        echo "fetched $asset $tag (verified)" >&2
    fi
    echo "$cache"
}

# Fetch the pinned FULL rclone release into vendor/cache/ (idempotent) and
# print its path on stdout. Tag: RCLONE_TAG env > vendor/rclone.tag.
#
# Deliberately the full build (`rclone-linux-<arch>.tar.gz`, ~20MB), NOT the
# slim `rclone-sandbox-*` one: the sandbox is a first-class host for the
# "connect a data source" UI, which needs the third-party backends (drive,
# onedrive, dropbox, s3) plus `lsjson`/`listremotes`. The slim build has only
# the `todoforai` backend and no `lsjson`, so connecting Google Drive on the
# cloud VM failed with "unknown command"/"didn't find backend". +5MB buys the
# same rclone surface the user's PC has.
#
# No .sha256 asset is published for the tarballs, so the digest is pinned here
# (vendor/rclone.sha256, keyed by "<tag> <asset>") and verified the same way.
rclone_fetch() {
    local tag asset cache base tmp expected actual
    tag="${RCLONE_TAG:-$(cat "$ASSETS_DIR/rclone.tag" 2>/dev/null || true)}"
    [ -n "$tag" ] || { echo "ERROR: no rclone tag (vendor/rclone.tag or RCLONE_TAG)" >&2; return 1; }
    case "${RCLONE_ARCH:-x64}" in
        x64|amd64|x86_64) asset="rclone-linux-amd64.tar.gz" ;;
        arm64|aarch64)    asset="rclone-linux-arm64.tar.gz" ;;
        *) echo "ERROR: unsupported RCLONE_ARCH: $RCLONE_ARCH" >&2; return 1 ;;
    esac
    cache="$ASSETS_DIR/cache/${tag}-${asset%.tar.gz}"
    if [ ! -f "$cache" ]; then
        expected="$(awk -v t="$tag" -v a="$asset" '$1==t && $2==a {print $3}' "$ASSETS_DIR/rclone.sha256" 2>/dev/null || true)"
        [ -n "$expected" ] || { echo "ERROR: no pinned sha256 for $asset $tag (vendor/rclone.sha256)" >&2; return 1; }
        base="https://github.com/todoforai/rclone-backend/releases/download/$tag"
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
        curl -fsSL "$base/$asset" -o "$tmp/a.tar.gz" || { echo "ERROR: download failed: $base/$asset" >&2; return 1; }
        actual="$(sha256sum "$tmp/a.tar.gz" | awk '{print $1}')"
        [ "$expected" = "$actual" ] || { echo "ERROR: sha256 mismatch ($asset $tag): want $expected got $actual" >&2; return 1; }
        tar -xzf "$tmp/a.tar.gz" -C "$tmp" rclone || { echo "ERROR: extract failed ($asset)" >&2; return 1; }
        mkdir -p "$ASSETS_DIR/cache"; chmod 0755 "$tmp/rclone"; mv "$tmp/rclone" "$cache"
        echo "fetched $asset $tag (verified)" >&2
    fi
    echo "$cache"
}

# Assert a fetched/cached rclone actually provides what both hosts need. The
# pinned digest covers the tarball, not the extracted (or hand-replaced) file
# in the cache, and "it downloaded" says nothing about the build variant — the
# slim `rclone-sandbox-*` build we used to ship passes every checksum yet lacks
# `lsjson` and the third-party backends the connect-a-source UI drives.
rclone_verify() {
    local bin="$1" missing=""
    [ -x "$bin" ] || { echo "ERROR: rclone not executable: $bin" >&2; return 1; }
    "$bin" version >/dev/null 2>&1 || { echo "ERROR: rclone binary does not run: $bin" >&2; return 1; }
    for cmd in lsjson listremotes config mount; do
        "$bin" "$cmd" --help >/dev/null 2>&1 || missing="$missing $cmd"
    done
    for be in todoforai drive onedrive dropbox s3; do
        "$bin" help backend "$be" >/dev/null 2>&1 || missing="$missing $be(backend)"
    done
    [ -z "$missing" ] || { echo "ERROR: rclone build is missing:$missing (slim build baked in? need the full rclone-linux-* asset)" >&2; return 1; }
}

catalog_sync() {
    [ -f "$CATALOG_SRC" ] || { echo "ERROR: catalog not found: $CATALOG_SRC" >&2; return 1; }
    mkdir -p "$ASSETS_DIR"
    cp -f "$CATALOG_SRC" "$ASSETS_DIR/tool_catalog.json"
    echo "✓ vendored tool_catalog.json → $ASSETS_DIR ($(du -h "$ASSETS_DIR/tool_catalog.json" | cut -f1))"
}

case "${1:-all}" in
    bridge)  bridge_fetch ;;
    rclone)  rclone_fetch ;;
    catalog) catalog_sync; echo "Commit vendor/tool_catalog.json so the standalone clone is self-sufficient." ;;
    --check)
        diff -q "$CATALOG_SRC" "$ASSETS_DIR/tool_catalog.json" >/dev/null 2>&1 \
            || { echo "ERROR: vendor/tool_catalog.json is stale — run scripts/sync-vendor.sh and commit." >&2; exit 1; }
        bridge_fetch >/dev/null || { echo "ERROR: pinned bridge release not fetchable (assets/bridge.tag)." >&2; exit 1; }
        # rclone IS checked here (unlike before): the cloud VM's data-source UI
        # depends on this exact binary, so a bad digest / renamed asset must
        # fail the check rather than silently ship an image without it.
        rclone_bin="$(rclone_fetch)" || { echo "ERROR: pinned rclone release not fetchable (assets/rclone.tag + assets/rclone.sha256)." >&2; exit 1; }
        rclone_verify "$rclone_bin" || exit 1
        echo "✓ vendor/ is in sync (catalog up to date, bridge $(cat "$ASSETS_DIR/bridge.tag") + rclone $(cat "$ASSETS_DIR/rclone.tag") fetchable)." ;;
    all)
        catalog_sync
        bridge_fetch >/dev/null
        echo "✓ bridge $(cat "$ASSETS_DIR/bridge.tag") cached under vendor/cache/"
        # rclone is best-effort here: a missing binary only disables the cloud
        # FUSE mount + data sources (the entrypoint is tolerant) and must not
        # block a rootfs build. `--check` is the strict gate.
        rclone_fetch >/dev/null 2>&1 \
            && echo "✓ rclone $(cat "$ASSETS_DIR/rclone.tag") cached under vendor/cache/" \
            || echo "… rclone $(cat "$ASSETS_DIR/rclone.tag" 2>/dev/null) not fetchable (cloud mount + data sources disabled)"
        echo "Commit vendor/tool_catalog.json so the standalone clone is self-sufficient." ;;
    *) echo "usage: $0 [all|catalog|bridge|rclone|--check]" >&2; exit 2 ;;
esac
