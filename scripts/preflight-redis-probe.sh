#!/usr/bin/env bash
# Pre-deploy probe: scan Redis/Dragonfly for sandbox records that violate
# the assumptions of commit 4736bd4 (single-pass reconcile, no Lite+VM
# duplicates for the same user).
#
# Reads only — never writes. Safe on prod.
#
# Output sections:
#   A. Active sandbox count per user (≥2 = needs attention)
#   B. Users with BOTH Lite and VM among any-state records (the corruption
#      risk: single-pass reconcile would loop-mount home.img while a VM
#      attaches the same image)
#   C. Per-uid filesystem layout under <user-homes>/ — old dir-style data
#      vs new home.img. Old data is invisible after deploy (mount shadows
#      the dir contents); migration needed if non-empty.
#
# Usage:
#   DRAGONFLY_URL=redis://:pw@host:port USER_HOMES_DIR=/var/lib/sbx/user-homes \
#     scripts/preflight-redis-probe.sh
#   # Or run on the prod host with its .env already sourced.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DRAGONFLY_URL:-}" && -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
fi
[[ -n "${DRAGONFLY_URL:-}" ]] || { echo "DRAGONFLY_URL not set" >&2; exit 1; }
command -v redis-cli >/dev/null || { echo "redis-cli not on PATH" >&2; exit 1; }
command -v jq >/dev/null        || { echo "jq not on PATH"        >&2; exit 1; }

# redis-cli accepts a redis:// URL via -u.
RC=(redis-cli -u "$DRAGONFLY_URL")

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
warn() { printf '  \033[1;33m! %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

# --- Pull all sandbox records once into a single JSON array ---
say "loading sandbox records from Redis"
mapfile -t KEYS < <("${RC[@]}" --scan --pattern 'sandbox:*' \
  | grep -vE '^sandbox:(active|user:|events:)')
echo "  ${#KEYS[@]} sandbox:<id> records"

if [[ ${#KEYS[@]} -eq 0 ]]; then
  ok "no sandbox records — nothing to migrate or reconcile"
  exit 0
fi

# MGET each in batches; assemble into a JSON array.
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
printf '%s\n' "${KEYS[@]}" | xargs -n 100 "${RC[@]}" mget \
  | jq -Rs 'split("\n") | map(select(length>0) | fromjson)' > "$TMP"
TOTAL=$(jq 'length' "$TMP")
ok "$TOTAL records parsed"

# --- A. Active count per user ---
say "A. users with multiple ACTIVE sandboxes"
ACTIVE_IDS=$("${RC[@]}" smembers sandbox:active | jq -Rs 'split("\n") | map(select(length>0))')
MULTI_ACTIVE=$(jq --argjson active "$ACTIVE_IDS" '
  map(select(.id as $i | $active | index($i)))
  | group_by(.user_id)
  | map({user_id: .[0].user_id, count: length, kinds: (map(.kind) | unique), ids: map(.id)})
  | map(select(.count > 1))
' "$TMP")
N=$(echo "$MULTI_ACTIVE" | jq 'length')
if [[ "$N" -eq 0 ]]; then
  ok "no user has >1 active sandbox"
else
  warn "$N user(s) have multiple active sandboxes:"
  echo "$MULTI_ACTIVE" | jq -r '.[] | "    \(.user_id)  count=\(.count)  kinds=\(.kinds|join(","))  ids=\(.ids|join(","))"'
fi

# --- B. Lite+VM mix across any-state records for same user ---
say "B. users with BOTH Lite and VM records (any state)"
MIXED=$(jq '
  group_by(.user_id)
  | map({
      user_id: .[0].user_id,
      kinds: (map(.kind) | unique),
      lite_states: (map(select(.kind=="lite") | .state) | unique),
      vm_states:   (map(select(.kind=="vm")   | .state) | unique),
    })
  | map(select(.kinds == ["lite","vm"] or .kinds == ["vm","lite"]))
' "$TMP")
N=$(echo "$MIXED" | jq 'length')
if [[ "$N" -eq 0 ]]; then
  ok "no user has both Lite and VM records — single-pass reconcile is safe"
else
  warn "$N user(s) have both kinds:"
  echo "$MIXED" | jq -r '.[] | "    \(.user_id)  lite=\(.lite_states|join(","))  vm=\(.vm_states|join(","))"'
  warn "If any of these have BOTH kinds in {running,paused,creating}, single-pass"
  warn "reconcile may double-mount the same home.img → ext4 corruption."
  warn "Mitigate before deploy: delete the stale-kind record(s) via admin API."
fi

# --- C. Filesystem layout under USER_HOMES_DIR ---
say "C. on-disk user-homes layout"
UHD="${USER_HOMES_DIR:-}"
if [[ -z "$UHD" ]]; then
  warn "USER_HOMES_DIR not set — skipping filesystem scan."
  warn "Set it (e.g. /var/lib/sandbox-manager/overlays/user-homes) and re-run for migration check."
else
  if [[ ! -d "$UHD" ]]; then
    ok "$UHD does not exist — no legacy data, fresh deploy is clean"
  else
    OLD_STYLE=()
    NEW_STYLE=0
    EMPTY=0
    while IFS= read -r -d '' uid_dir; do
      [[ "$uid_dir" == "$UHD" ]] && continue
      if [[ -f "$uid_dir/home.img" ]]; then
        NEW_STYLE=$((NEW_STYLE + 1))
      else
        # Anything besides .lock counts as legacy data.
        nonlock=$(find "$uid_dir" -maxdepth 1 -mindepth 1 ! -name .lock -printf . | wc -c)
        if [[ "$nonlock" -gt 0 ]]; then
          OLD_STYLE+=("$uid_dir")
        else
          EMPTY=$((EMPTY + 1))
        fi
      fi
    done < <(find "$UHD" -maxdepth 1 -mindepth 1 -type d -print0)

    echo "  new-style (has home.img):  $NEW_STYLE"
    echo "  empty (.lock only / none): $EMPTY"
    echo "  legacy (dir with files):   ${#OLD_STYLE[@]}"
    if [[ ${#OLD_STYLE[@]} -gt 0 ]]; then
      warn "Legacy users — their data will be hidden by the new home.img mount:"
      for d in "${OLD_STYLE[@]}"; do
        sz=$(du -sh "$d" 2>/dev/null | cut -f1)
        echo "    $d  ($sz)"
      done
      warn "Run a migration (rsync legacy → freshly-mkfs'd home.img) before deploy"
      warn "if any of these uids matter. Otherwise document the data loss."
    fi
  fi
fi

say "DONE"
