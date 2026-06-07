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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
OCI_DIR="$ROOT/oci"
ASSETS_DIR="$ROOT/assets"

IMAGE="${IMAGE:-sandbox-rootfs:dev}"
TOOL_CATALOG_JSON="${TOOL_CATALOG_JSON:-$ASSETS_DIR/tool_catalog.json}"

# --- bridge binary: reuse sync-vendor.sh's resolution (build or pinned release).
echo ">> resolving bridge binary..."
BRIDGE_BIN="${BRIDGE_BIN:-$("$SCRIPT_DIR/sync-vendor.sh" bridge)}"
[ -f "$BRIDGE_BIN" ] || { echo "ERROR: bridge binary not found: $BRIDGE_BIN" >&2; exit 1; }
echo "   bridge: $BRIDGE_BIN ($(ls -lh "$BRIDGE_BIN" | awk '{print $5}'))"
cp "$BRIDGE_BIN" "$OCI_DIR/todoforai-bridge"
trap 'rm -f "$OCI_DIR/todoforai-bridge"' EXIT

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

echo ">> docker build $IMAGE"
# --provenance/--sbom=false: keep it a single-manifest image. The buildx
# attestation manifest makes the result a manifest *list*, which containerd's
# `image import` rejects ("no unpack platforms defined") when loading into the
# devmapper snapshotter for Kata.
docker build \
    --provenance=false --sbom=false \
    --build-arg BUN_PREINSTALL="$BUN_PREINSTALL" \
    -t "$IMAGE" \
    -f "$OCI_DIR/Dockerfile" \
    "$OCI_DIR"

echo ">> built $IMAGE"
[ "${PUSH:-0}" = "1" ] && { echo ">> docker push $IMAGE"; docker push "$IMAGE"; }
echo "done."
