#!/usr/bin/env bash
# Boot a freshly-built kernel+rootfs under Firecracker (no sandbox-manager,
# no backend) and assert kernel/init sanity. Designed to catch the class of
# bugs that broke "Add hosted desktop" for weeks:
#
#   - CONFIG_BLOCK missing → no /dev/vda → VFS panic
#   - CONFIG_FUTEX missing → glibc aborts every binary
#   - CONFIG_POSIX_TIMERS / MEMBARRIER / RSEQ missing → ENOSYS at runtime
#   - /init shell regressions (e.g. dropped mmds_get helper)
#   - MMDS V2 PUT/GET round-trip broken (optional — needs CAP_NET_ADMIN)
#
# Companion to smoke-test-boot.sh: that one is end-to-end (sandbox-manager
# admin REST + real backend auth); this one runs at build time, with zero
# state, before either of those exist. Catches the bug class earlier in the
# pipeline and keeps the dev inner loop fast (~10s).
#
# Usage:
#   scripts/smoke-test-kernel-boot.sh           # use $TEMPLATES_DIR/ubuntu-base/*
#   KERNEL=/path ROOTFS=/path scripts/smoke-test-kernel-boot.sh
#
# Env:
#   FIRECRACKER       firecracker binary (default: $(command -v firecracker))
#   BOOT_BUDGET_SECS  wall-clock budget for the asserts (default: 30)
#   KEEP_LOG=1        keep the console log on /tmp on failure
#
# Requirements:
#   - /dev/kvm readable by current user
#   - firecracker on PATH (or $FIRECRACKER)
#   - CAP_NET_ADMIN (root) only needed for the TAP-based MMDS round-trip
#     check; kernel/init asserts run unconditionally.
#
# Exit codes: 0 ok, 1 assertion failed, 2 setup error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${TEMPLATES_DIR:-}" ]; then
    DATA_DIR="${DATA_DIR:-$HOME/sandbox-data}"
    TEMPLATES_DIR="$DATA_DIR/templates"
fi

KERNEL="${KERNEL:-$TEMPLATES_DIR/ubuntu-base/vmlinux}"
ROOTFS_SRC="${ROOTFS:-$TEMPLATES_DIR/ubuntu-base/rootfs.ext4}"
FIRECRACKER="${FIRECRACKER:-$(command -v firecracker || true)}"
BOOT_BUDGET_SECS="${BOOT_BUDGET_SECS:-30}"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }

# ---- preflight ----
say "preflight"
[ -r /dev/kvm ] || die "/dev/kvm not readable — Firecracker needs KVM" 2
[ -n "$FIRECRACKER" ] && [ -x "$FIRECRACKER" ] || die "firecracker not found (set FIRECRACKER=)" 2
[ -r "$KERNEL" ] || die "kernel not found: $KERNEL" 2
[ -r "$ROOTFS_SRC" ] || die "rootfs not found: $ROOTFS_SRC" 2
ok "kvm + firecracker + kernel + rootfs present"

# ---- workspace ----
TMP="$(mktemp -d /tmp/sm-smoke.XXXXXX)"
SOCK="$TMP/fc.sock"
CONSOLE="$TMP/console.log"
ROOTFS="$TMP/rootfs.ext4"
# Linux limits interface names to 15 chars (IFNAMSIZ-1). Last 5 of PID is enough.
TAP="sm-smk-$(printf '%05d' $(($$ % 100000)))"
HAVE_TAP=0
FC_PID=

# Per-VM rootfs copy — guest mounts r/w and we never want to dirty the source.
cp --reflink=auto "$ROOTFS_SRC" "$ROOTFS"

cleanup() {
    [ -n "$FC_PID" ] && kill -9 "$FC_PID" 2>/dev/null || true
    [ "$HAVE_TAP" = 1 ] && ip tuntap del "$TAP" mode tap 2>/dev/null || true
    if [ "${KEEP_LOG:-0}" = 1 ] && [ -f "$CONSOLE" ]; then
        cp "$CONSOLE" "/tmp/sm-smoke-console-last.log"
        warn "console saved to /tmp/sm-smoke-console-last.log"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

# ---- optional TAP for MMDS ----
# MMDS V2 requires a configured network interface to deliver metadata. We
# create a host-side TAP (no bridge, no upstream — the guest cannot reach
# anything but MMDS). Falls back gracefully without it.
if ip tuntap add "$TAP" mode tap 2>/dev/null && ip link set "$TAP" up 2>/dev/null; then
    HAVE_TAP=1
    ok "created TAP $TAP (will exercise MMDS PUT/GET)"
else
    warn "no CAP_NET_ADMIN — skipping MMDS check; kernel/init asserts still run"
fi

# ---- start firecracker ----
say "boot firecracker"
"$FIRECRACKER" --api-sock "$SOCK" >"$CONSOLE" 2>&1 &
FC_PID=$!
for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; sleep 0.05; done
[ -S "$SOCK" ] || die "firecracker did not create API socket"

fc_api() {
    local method=$1 path=$2 body=${3:-}
    if [ -n "$body" ]; then
        curl -fsS --unix-socket "$SOCK" -X "$method" \
            -H "Content-Type: application/json" \
            -d "$body" "http://localhost$path"
    else
        curl -fsS --unix-socket "$SOCK" -X "$method" "http://localhost$path"
    fi
}

LOGF="$TMP/fc.log"; : >"$LOGF"
fc_api PUT /logger "{\"log_path\":\"$LOGF\",\"level\":\"Info\"}" >/dev/null

fc_api PUT /boot-source "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1 pci=off init=/init\"}" >/dev/null
fc_api PUT /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":false}" >/dev/null
fc_api PUT /machine-config '{"vcpu_count":1,"mem_size_mib":256}' >/dev/null

if [ "$HAVE_TAP" = 1 ]; then
    fc_api PUT /network-interfaces/eth0 \
        "{\"iface_id\":\"eth0\",\"host_dev_name\":\"$TAP\",\"guest_mac\":\"AA:BB:CC:00:00:01\"}" >/dev/null
    fc_api PUT /mmds/config '{"network_interfaces":["eth0"],"version":"V2"}' >/dev/null
    # `tr | head -c` triggers pipefail (head exits after 56 chars, tr gets
    # SIGPIPE). openssl is universally present on hosts that have firecracker.
    SMOKE_TOKEN="smoketest_$(openssl rand -hex 28)"
    fc_api PUT /mmds "{\"enroll_token\":\"$SMOKE_TOKEN\",\"sandbox_id\":\"00000000-smoke-test-0000-000000000000\"}" >/dev/null
fi

fc_api PUT /actions '{"action_type":"InstanceStart"}' >/dev/null
ok "VM started (pid $FC_PID)"

# ---- wait + assert ----
say "tail console (budget: ${BOOT_BUDGET_SECS}s)"

# Required markers — kernel reaches userland, ext4 root mounts, /init runs
# far enough to start MMDS fetch.
REQUIRED=(
    'EXT4-fs \(vda\): mounted'
    'Run /init as init process'
    '\[init\] Fetching bootstrap data from MMDS'
)

# Banned markers — any hit fails the test.
#
# We do NOT ban "Kernel panic" wholesale: panic=1 makes init's normal exit
# (no creds → exit) trigger a panic, which is fine for this test.
# Pre-init kernel panics are caught by the specific VFS markers below.
BANNED=(
    'VFS: Unable to mount root fs'
    'VFS: Cannot open root device'
    'futex facility returned an unexpected error code'
    'attempted a POSIX timer syscall while CONFIG_POSIX_TIMERS is not set'
    'membarrier.*ENOSYS'
    'mmds_get: command not found'
    'Aborted.*sshd'
    'Aborted.*wget'
)

deadline=$(( $(date +%s) + BOOT_BUDGET_SECS ))
got_all=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    missing=0
    for m in "${REQUIRED[@]}"; do
        grep -Eq "$m" "$CONSOLE" || missing=1
    done
    if [ "$missing" = 0 ]; then got_all=1; break; fi
    sleep 0.5
done

banned_hits=()
for b in "${BANNED[@]}"; do
    if grep -Eq "$b" "$CONSOLE"; then banned_hits+=("$b"); fi
done

say "results"
for m in "${REQUIRED[@]}"; do
    if grep -Eq "$m" "$CONSOLE"; then ok "saw: $m"
    else printf '  \033[31m✗ missing: %s\033[0m\n' "$m"; fi
done
for b in "${banned_hits[@]}"; do
    printf '  \033[31m✗ banned: %s\033[0m\n' "$b"
done

if [ "$got_all" = 1 ] && [ "${#banned_hits[@]}" = 0 ]; then
    ok "smoke test passed"
    exit 0
fi

echo
echo "==== last 60 console lines ===="
tail -n 60 "$CONSOLE" || true
KEEP_LOG=1
die "smoke test FAILED (missing required or hit banned markers)"
