#!/usr/bin/env bash
# Smoke-test the per-user home-disk feature (commits df25eae..HEAD) locally.
#
# Three layers, fastest first. Stops at the first failure so you can act
# on the most informative error. Pass --skip-mount to skip the sudo layer
# on hosts where you can't / don't want to elevate.
#
# Usage:
#   scripts/smoke-test-user-home.sh           # all layers
#   scripts/smoke-test-user-home.sh --skip-mount

set -euo pipefail
SELF=$(realpath "$0")
cd "$(dirname "$0")/.."

SKIP_MOUNT=0
[[ "${1:-}" == "--skip-mount" ]] && SKIP_MOUNT=1

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Running under sudo? cargo lives in the invoking user's $HOME, not root's.
# Re-resolve PATH from SUDO_USER so `cargo`/`rustc` are found.
if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  export PATH="$USER_HOME/.cargo/bin:$PATH"
fi
LOG_DIR=$(mktemp -d)
trap 'echo "Logs kept in $LOG_DIR"' EXIT

say "1/4 host readiness"
for bin in mkfs.ext4 mount umount mountpoint; do
  command -v "$bin" >/dev/null || die "$bin not on PATH (install e2fsprogs / util-linux)"
  ok "$bin present"
done
[[ -r /sys/module/loop/parameters/max_loop ]] && \
  ok "loop max_loop=$(cat /sys/module/loop/parameters/max_loop) (bump via modprobe loop max_loop=256 if >8 concurrent sandboxes expected)"

say "2/4 unit tests — pure logic (no root, no mkfs)"
cargo test --bin sandbox-manager service::user_home 2>&1 | tee "$LOG_DIR/unit.log"
grep -q "test result: ok" "$LOG_DIR/unit.log" || die "unit tests failed"
ok "pure-logic tests passed"

say "3/4 ensure_disk — sparse mkfs.ext4 round-trip (no root)"
cargo test --bin sandbox-manager service::user_home -- --ignored 2>&1 | tee "$LOG_DIR/mkfs.log"
grep -q "test result: ok" "$LOG_DIR/mkfs.log" || die "ensure_disk tests failed"
ok "ensure_disk sparse + idempotent + non-destructive"

if [[ $SKIP_MOUNT -eq 1 ]]; then
  say "4/4 SKIPPED (--skip-mount)"
  echo "Run with sudo for full coverage:"
  echo "  sudo -E $SELF"
  exit 0
fi

say "4/4 LiteBackend — loop-mount round-trip (needs root)"
TEST_BIN=$(cargo test --bin sandbox-manager --no-run --message-format=json 2>/dev/null \
  | jq -r 'select(.profile.test == true) | .executable' | head -1)
[[ -x "$TEST_BIN" ]] || die "could not locate test binary"
ok "test binary: $TEST_BIN"

RUN=("$TEST_BIN" vm::lite::tests:: --ignored --test-threads=1)
[[ $EUID -eq 0 ]] || RUN=(sudo "${RUN[@]}")
"${RUN[@]}" 2>&1 | tee "$LOG_DIR/mount.log"
grep -q "test result: ok" "$LOG_DIR/mount.log" || die "mount tests failed"
ok "loop-mount provision/destroy round-trip + anonymous plain-dir branch green"

# Leftover loop devices = destroy leak. Tempdirs live under TMPDIR (usually /tmp).
LEAKS=$(losetup -a 2>/dev/null | grep -c "${TMPDIR:-/tmp}/\.tmp" || true)
if [[ $LEAKS -gt 0 ]]; then
  losetup -a | grep "${TMPDIR:-/tmp}/\.tmp" >&2
  die "$LEAKS leftover loop device(s) — destroy/umount path leaked"
fi
ok "no leftover /dev/loopN devices"

say "ALL GREEN"
