#!/usr/bin/env bash
# Update the preinstalled TODOforAI CLI tools on a LIVE box to latest, without a
# full template rebuild. Driven by the `preinstallCloud` set in tool_catalog.json
# (same source of truth the rootfs builds use).
#
# Auto-detects which install surface this box uses and updates in place:
#   1. bun-global   (ubuntu-base VM)  → `bun add -g <pkgs>@latest`
#   2. lib bundle   (cli-lite bwrap)  → re-`bun build` from api-apps/<dir>/src/cli.ts
#   3. ~/.todoforai/tools (dev/npm)   → `npm install <pkgs>@latest` in that dir
#
# Usage:
#   ./scripts/update-tools.sh                  # auto-detect surface, update all catalog pkgs
#   ./scripts/update-tools.sh --surface npm    # force a surface: bun|lib|npm
#   ./scripts/update-tools.sh @todoforai/vault # update only the given package(s)
#   TOOL_CATALOG_JSON=/path/catalog.json ./scripts/update-tools.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Prefer monorepo source of truth; fall back to vendored copy (standalone clones).
TOOL_CATALOG_JSON="${TOOL_CATALOG_JSON:-$REPO_ROOT/packages/shared-fbe/src/tool_catalog.json}"
[ -f "$TOOL_CATALOG_JSON" ] || TOOL_CATALOG_JSON="$SCRIPT_DIR/../vendor/tool_catalog.json"
API_APPS_DIR="${API_APPS_DIR:-$REPO_ROOT/api-apps}"
TOOLS_DIR="${TODOFORAI_TOOLS_DIR:-$HOME/.todoforai/tools}"

SURFACE=""
EXPLICIT_PKGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --surface) SURFACE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) EXPLICIT_PKGS+=("$1"); shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
[ -f "$TOOL_CATALOG_JSON" ] || { echo "ERROR: catalog not found: $TOOL_CATALOG_JSON" >&2; exit 1; }

# preinstallCloud npm/bun packages from the catalog (bare names, latest at install).
mapfile -t PKGS < <(jq -r '
  to_entries
  | map(select(.value.preinstallCloud == true and (.value.installer == "npm" or .value.installer == "bun")))
  | map(.value.pkg) | .[]
' "$TOOL_CATALOG_JSON")
# Restrict to explicitly-requested packages, if any.
if [ "${#EXPLICIT_PKGS[@]}" -gt 0 ]; then PKGS=("${EXPLICIT_PKGS[@]}"); fi
[ "${#PKGS[@]}" -gt 0 ] || { echo "no packages to update"; exit 0; }

# Auto-detect surface when not forced.
if [ -z "$SURFACE" ]; then
  if [ -d /lib/tfa-vault ] || ls /lib/*/cli.js >/dev/null 2>&1; then SURFACE=lib
  elif [ -d "$TOOLS_DIR/node_modules" ]; then SURFACE=npm
  elif command -v bun >/dev/null 2>&1; then SURFACE=bun
  else echo "ERROR: could not detect install surface (no /lib bundle, no $TOOLS_DIR, no bun)" >&2; exit 1; fi
fi
echo "==> surface: $SURFACE   packages: ${PKGS[*]}"

case "$SURFACE" in
  bun)
    command -v bun >/dev/null 2>&1 || { echo "ERROR: bun not found" >&2; exit 1; }
    export BUN_INSTALL="${BUN_INSTALL:-/usr/local}"
    latest=(); for p in "${PKGS[@]}"; do latest+=("${p}@latest"); done
    bun add -g "${latest[@]}"
    ;;
  npm)
    command -v npm >/dev/null 2>&1 || { echo "ERROR: npm not found" >&2; exit 1; }
    [ -d "$TOOLS_DIR" ] || { echo "ERROR: $TOOLS_DIR not found" >&2; exit 1; }
    latest=(); for p in "${PKGS[@]}"; do latest+=("${p}@latest"); done
    ( cd "$TOOLS_DIR" && npm install "${latest[@]}" )
    ;;
  lib)
    # cli-lite bundles from local repo source — rebuild bundles in place. This
    # picks up working-tree changes (the version is whatever the source says).
    command -v bun >/dev/null 2>&1 || { echo "ERROR: bun not found" >&2; exit 1; }
    [ -d "$API_APPS_DIR" ] || { echo "ERROR: api-apps source absent ($API_APPS_DIR) — rebuild the template instead" >&2; exit 1; }
    ( cd "$API_APPS_DIR" && (bun install --frozen-lockfile 2>/dev/null || bun install) )
    for pkg in "${PKGS[@]}"; do
      # Resolve catalog key (== /lib/<key>) from the package whose `bin` matches,
      # then locate that package's src/cli.ts.
      key=""; src_dir=""
      for pj in "$API_APPS_DIR"/*/package.json; do
        [ -f "$pj" ] || continue
        if [ "$(jq -r '.name' "$pj")" = "$pkg" ]; then
          src_dir="$(dirname "$pj")"
          key="$(jq -r '(.bin|objects)|keys|.[0] // empty' "$pj")"
          break
        fi
      done
      if [ -z "$key" ] || [ ! -f "$src_dir/src/cli.ts" ]; then
        echo "  skip $pkg (no src/cli.ts found under $API_APPS_DIR)"; continue
      fi
      echo "==> rebuilding /lib/$key from $src_dir/src/cli.ts"
      ( cd "$src_dir" && bun build src/cli.ts --target=node --outfile "/lib/$key/cli.js" )
    done
    ;;
  *) echo "ERROR: unknown surface '$SURFACE' (use bun|lib|npm)" >&2; exit 1 ;;
esac

echo "==> done. Installed versions:"
for pkg in "${PKGS[@]}"; do
  # Map pkg → bin via catalog versionCmd where possible; fall back to the pkg name.
  vcmd="$(jq -r --arg p "$pkg" 'to_entries[] | select(.value.pkg==$p) | .value.versionCmd // empty' "$TOOL_CATALOG_JSON" | head -1)"
  if [ -n "$vcmd" ]; then printf '  %-26s %s\n' "$pkg" "$(eval "$vcmd" 2>/dev/null || echo '?')"; fi
done
