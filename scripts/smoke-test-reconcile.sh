#!/usr/bin/env bash
# Smoke test the VM liveness reconciler against a running sandbox-manager.
#
# What it does:
#   1. List active VMs via /admin/api/sandbox.
#   2. Pick one (or the id passed as $1), capture its pid from the listing.
#   3. SIGKILL the Firecracker process.
#   4. Wait up to RECONCILE_INTERVAL_SECS + a buffer, polling /admin/api/sandbox
#      for the sandbox's state.
#   5. Assert: state transitioned to "error" with a "process gone" reason.
#
# Requires:
#   - A running sandbox-manager (local or via SSH tunnel to staging).
#   - At least one VM sandbox in state Running.
#   - $SANDBOX_MANAGER_ADMIN_KEY exported (matches .env / prod config).
#   - kill rights on the Firecracker pid (root or same user).
#
# Usage:
#   scripts/smoke-test-reconcile.sh                  # auto-pick first running VM
#   scripts/smoke-test-reconcile.sh <sandbox-id>     # target a specific VM
#
# Env knobs:
#   ADMIN_URL=http://127.0.0.1:8210
#   SANDBOX_MANAGER_ADMIN_KEY=<bearer>
#   RECONCILE_INTERVAL_SECS=10    (must match server's setting)
#   POLL_BUDGET_SECS=20           (how long after kill we wait for Error)

set -euo pipefail

ADMIN_URL="${ADMIN_URL:-http://127.0.0.1:8210}"
KEY="${SANDBOX_MANAGER_ADMIN_KEY:?SANDBOX_MANAGER_ADMIN_KEY required}"
RECONCILE_INTERVAL_SECS="${RECONCILE_INTERVAL_SECS:-10}"
POLL_BUDGET_SECS="${POLL_BUDGET_SECS:-$((RECONCILE_INTERVAL_SECS + 10))}"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

api() { curl -sS -f -H "Authorization: Bearer $KEY" "$@"; }

command -v jq >/dev/null || die "jq required"

say "1/4  list sandboxes"
LIST=$(api "$ADMIN_URL/admin/api/sandbox") || die "admin API unreachable at $ADMIN_URL"

TARGET="${1:-$(jq -r '[.[] | select(.kind=="vm" and .state=="running" and .pid)] | .[0].id // empty' <<<"$LIST")}"
[[ -n "$TARGET" ]] || die "no running VM sandbox found (and none passed as arg)"

ROW=$(jq -r --arg id "$TARGET" '.[] | select(.id==$id)' <<<"$LIST")
[[ -n "$ROW" ]] || die "sandbox $TARGET not found in listing"
PID=$(jq -r '.pid // empty' <<<"$ROW")
STATE=$(jq -r '.state' <<<"$ROW")
[[ -n "$PID" ]] || die "sandbox $TARGET has no pid"
[[ "$STATE" == "running" ]] || die "sandbox $TARGET state=$STATE (expected running)"
ok "target=$TARGET pid=$PID state=$STATE"

say "2/4  SIGKILL firecracker pid $PID"
if ! kill -9 "$PID" 2>/dev/null; then
    # Maybe we don't have permission as the local user — try sudo once.
    sudo kill -9 "$PID" || die "could not kill pid $PID"
fi
ok "sent SIGKILL"

say "3/4  poll for state=error (budget ${POLL_BUDGET_SECS}s)"
DEADLINE=$(( $(date +%s) + POLL_BUDGET_SECS ))
while (( $(date +%s) < DEADLINE )); do
    NOW_STATE=$(api "$ADMIN_URL/admin/api/sandbox" \
        | jq -r --arg id "$TARGET" '.[] | select(.id==$id) | .state')
    if [[ "$NOW_STATE" == "error" ]]; then
        ok "reconciler flipped state to Error"
        break
    fi
    printf '  … state=%s\n' "${NOW_STATE:-<gone>}"
    sleep 2
done

FINAL=$(api "$ADMIN_URL/admin/api/sandbox" | jq -r --arg id "$TARGET" '.[] | select(.id==$id)')
FINAL_STATE=$(jq -r '.state' <<<"$FINAL")
FINAL_ERR=$(jq -r '.error // ""' <<<"$FINAL")
[[ "$FINAL_STATE" == "error" ]] || die "still state=$FINAL_STATE after ${POLL_BUDGET_SECS}s; reconcile loop not working"
[[ "$FINAL_ERR" == *"process gone"* ]] || \
    printf '  \033[33m!\033[0m error message unexpected: %s\n' "$FINAL_ERR"
ok "error: $FINAL_ERR"

say "4/4  cleanup (delete sandbox)"
api -X DELETE "$ADMIN_URL/admin/api/sandbox/$TARGET" >/dev/null \
    && ok "deleted $TARGET" \
    || die "delete failed — check TAP/IP for leaks"

printf '\n\033[1;32mreconciler smoke OK\033[0m\n'
