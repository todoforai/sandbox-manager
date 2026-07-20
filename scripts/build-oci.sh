#!/usr/bin/env bash
# Build the sandbox rootfs OCI image (for Kata + Firecracker on containerd).
# Replaces build-ubuntu-rootfs.sh + build-kernel.sh + build-templates.sh —
# Kata ships the guest kernel, so there's nothing to build but the userland.
#
# Resolves the bridge binary (monorepo build > pinned release via sync-vendor)
# and the preinstall CLI list (tool_catalog.json), then `docker build`s the
# image at oci/Dockerfile.
#
# Usage:
#   scripts/build-oci.sh                         # build sandbox-rootfs:dev
#   IMAGE=registry/foo/sandbox-rootfs:v1 PUSH=1 scripts/build-oci.sh
#   NO_CACHE=1 scripts/build-oci.sh              # force fresh layers (e.g. unpinned
#                                                # bun packages published a new version)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
OCI_DIR="$ROOT/oci"
ASSETS_DIR="$ROOT/assets"

IMAGE="${IMAGE:-sandbox-rootfs:dev}"
TOOL_CATALOG_JSON="${TOOL_CATALOG_JSON:-$ASSETS_DIR/tool_catalog.json}"

# Drift guard: when the monorepo source is present (dev), the vendored copy must
# match it — otherwise we'd build a stale catalog. No-op in the standalone prod
# clone, where the source is absent (that's the whole point of vendoring).
CATALOG_SRC="$(dirname "$ROOT")/packages/shared-fbe/src/tool_catalog.json"
if [ -f "$CATALOG_SRC" ] && ! diff -q "$CATALOG_SRC" "$TOOL_CATALOG_JSON" >/dev/null 2>&1; then
    echo "ERROR: assets/tool_catalog.json is stale — run scripts/sync-vendor.sh catalog and commit." >&2
    exit 1
fi

# --- bridge binary: reuse sync-vendor.sh's resolution (build or pinned release).
echo ">> resolving bridge binary..."
BRIDGE_BIN="${BRIDGE_BIN:-$("$SCRIPT_DIR/sync-vendor.sh" bridge)}"
[ -f "$BRIDGE_BIN" ] || { echo "ERROR: bridge binary not found: $BRIDGE_BIN" >&2; exit 1; }
echo "   bridge: $BRIDGE_BIN ($(ls -lh "$BRIDGE_BIN" | awk '{print $5}'))"
cp "$BRIDGE_BIN" "$OCI_DIR/todoforai-bridge"
trap 'rm -f "$OCI_DIR/todoforai-bridge"' EXIT

# --- slim rclone (todoforai backend only): baked in like the bridge so the
# sandbox can FUSE-mount the user's cloud workspace. Best-effort — if the
# pinned release asset isn't published yet, drop it and the guest entrypoint
# simply skips the mount (a non-essential feature, must not fail the build).
rm -f "$OCI_DIR/rclone"
if RCLONE_BIN="$("$SCRIPT_DIR/sync-vendor.sh" rclone 2>/dev/null)" && [ -f "$RCLONE_BIN" ]; then
    cp "$RCLONE_BIN" "$OCI_DIR/rclone"
    echo "   rclone: $RCLONE_BIN ($(ls -lh "$RCLONE_BIN" | awk '{print $5}'))"
else
    echo "   WARN: slim rclone not fetchable (release not published?) — cloud mount disabled in this image" >&2
fi
# Empty placeholder keeps the Dockerfile COPY valid when the fetch is skipped.
[ -f "$OCI_DIR/rclone" ] || : > "$OCI_DIR/rclone"

# --- preinstall CLI list from the tool catalog (same query as the old rootfs).
BUN_PREINSTALL=""
if [ -f "$TOOL_CATALOG_JSON" ] && command -v jq >/dev/null 2>&1; then
    BUN_PREINSTALL=$(jq -r '
        to_entries
        | map(select(.value.preinstallCloud == true and (.value.installer == "bun" or .value.installer == "npm")))
        | map(.value.pkg) | join(" ")
    ' "$TOOL_CATALOG_JSON")
fi
echo "   preinstall: ${BUN_PREINSTALL:-(none)}"

# --- browser-manager-cli: a static C binary (not bun/npm, not in apt), so bake
# it in like the bridge. URL comes from the catalog (single source of truth).
# Best-effort: if the release isn't published yet the image still builds without
# it (the edge auto-installer fetches it lazily on first use as a fallback).
rm -f "$OCI_DIR/browser-manager-cli"
if [ -f "$TOOL_CATALOG_JSON" ] && command -v jq >/dev/null 2>&1; then
    BMCLI_ARCH="${BMCLI_ARCH:-x86_64}"
    BMCLI_URL=$(jq -r --arg k "linux-$BMCLI_ARCH" '."browser-manager-cli".binary[$k].url // empty' "$TOOL_CATALOG_JSON")
    if [ -n "$BMCLI_URL" ]; then
        echo ">> fetching browser-manager-cli: $BMCLI_URL"
        if curl -fsSL "$BMCLI_URL" -o "$OCI_DIR/browser-manager-cli"; then
            chmod 0755 "$OCI_DIR/browser-manager-cli"
            echo "   browser-manager-cli: $(ls -lh "$OCI_DIR/browser-manager-cli" | awk '{print $5}')"
        else
            echo "   WARN: browser-manager-cli download failed (release not published yet?) — skipping bake-in" >&2
            rm -f "$OCI_DIR/browser-manager-cli"
        fi
    fi
fi
# An empty placeholder keeps the Dockerfile COPY valid when the fetch is skipped.
[ -f "$OCI_DIR/browser-manager-cli" ] || : > "$OCI_DIR/browser-manager-cli"
trap 'rm -f "$OCI_DIR/todoforai-bridge" "$OCI_DIR/browser-manager-cli" "$OCI_DIR/rclone"' EXIT

# Bust the bun-preinstall layer each build by default so unpinned catalog
# packages (todoforai-cli, tfa-vault, …) land at latest. Set BUN_CACHE_BUST=0
# to reuse the layer; NO_CACHE=1 still rebuilds everything.
BUN_CACHE_BUST="${BUN_CACHE_BUST:-$(date -u +%Y%m%d%H%M%S)}"
[ "$BUN_CACHE_BUST" = "0" ] && BUN_CACHE_BUST=""

echo ">> docker build $IMAGE (bridge=$(cat "$ASSETS_DIR/bridge.tag" 2>/dev/null || echo '?'), bun_bust=${BUN_CACHE_BUST:-none})"
# --provenance/--sbom=false: keep it a single-manifest image. The buildx
# attestation manifest makes the result a manifest *list*, which containerd's
# `image import` rejects ("no unpack platforms defined") when loading into the
# devmapper snapshotter for Kata.
docker build \
    ${NO_CACHE:+--no-cache} \
    --provenance=false --sbom=false \
    --build-arg BUN_PREINSTALL="$BUN_PREINSTALL" \
    --build-arg BUN_CACHE_BUST="$BUN_CACHE_BUST" \
    -t "$IMAGE" \
    -f "$OCI_DIR/Dockerfile" \
    "$OCI_DIR"

echo ">> built $IMAGE"
[ "${PUSH:-0}" = "1" ] && { echo ">> docker push $IMAGE"; docker push "$IMAGE"; }

# Dev / air-gapped: with no registry to pull from, load the image straight into
# containerd's namespace so the manager's GetImage finds it (it pulls from
# Docker Hub otherwise → "pull access denied"). The imported ref + namespace
# MUST match the manager's SANDBOX_ROOTFS_IMAGE + CONTAINERD_NAMESPACE — for a
# bare IMAGE like sandbox-rootfs:dev, docker tags it docker.io/library/<IMAGE>,
# which is what .env.development's SANDBOX_ROOTFS_IMAGE points at. The NS
# default here mirrors .env.development (default), NOT the manager's built-in
# default (sandbox); override CONTAINERD_NAMESPACE if your env differs.
if [ "${IMPORT:-0}" = "1" ]; then
    NS="${CONTAINERD_NAMESPACE:-default}"
    case "$IMAGE" in */*) REF="$IMAGE" ;; *) REF="docker.io/library/$IMAGE" ;; esac
    echo ">> importing $REF into containerd ns=$NS (needs root)"
    docker save "$REF" | sudo ctr -n "$NS" images import -
    echo ">> imported. The manager unpacks it into devmapper on first create."
fi
echo "done."
