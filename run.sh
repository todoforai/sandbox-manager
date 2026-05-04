#!/bin/bash
# Run sandbox-manager. Selects .env vs .env.development via NODE_ENV.
#
#   ./run.sh              # dev  (loads .env.development, mock VMs)
#   ./run.sh prod         # prod (loads .env, real KVM — needs sudo for TAP)
#   NODE_ENV=production ./run.sh   # same as `./run.sh prod`
#
# Build once with `cargo build --release`. This script runs the built binary.

set -e
cd "$(dirname "$0")"

MODE="${1:-${NODE_ENV:-development}}"
case "$MODE" in
    prod|production) export NODE_ENV=production ;;
    dev|development) export NODE_ENV=development ;;
    *) echo "usage: $0 [dev|prod]" >&2; exit 2 ;;
esac

# Prefer ./sandbox-manager (deploy.sh copies the release binary here);
# fall back to the cargo target dir for local dev.
if [ -x ./sandbox-manager ]; then
    BIN=./sandbox-manager
else
    BIN=target/release/sandbox-manager
    [ -x "$BIN" ] || cargo build --release
fi

# CAP_NET_ADMIN+CAP_NET_RAW are required for TAP device management.
# Prod: applied at deploy time (deploy.sh) AND PM2 runs as root anyway.
# Dev: cargo rebuilds wipe file caps — re-apply via passwordless sudoers entry.
# See /etc/sudoers.d/sandbox-manager-setcap (one-time host setup).
if ! getcap "$BIN" 2>/dev/null | grep -q cap_net_admin; then
    if sudo -n setcap cap_net_admin,cap_net_raw=eip "$BIN" 2>/dev/null; then
        echo "[run.sh] re-applied CAP_NET_ADMIN to $BIN"
    fi
fi

if [ "$(id -u)" -ne 0 ] && ! getcap "$BIN" 2>/dev/null | grep -q cap_net_admin; then
    echo "ERROR: $BIN lacks CAP_NET_ADMIN and not running as root." >&2
    echo "Fix (one-time): sudo tee /etc/sudoers.d/sandbox-manager-setcap <<EOF" >&2
    echo "$(id -un) ALL=(root) NOPASSWD: /usr/sbin/setcap cap_net_admin\\,cap_net_raw=eip $(readlink -f "$BIN")" >&2
    echo "EOF" >&2
    echo "Then: sudo chmod 440 /etc/sudoers.d/sandbox-manager-setcap" >&2
    exit 1
fi

# Startup self-check: log effective cap state so regressions surface in pm2 logs.
echo "[run.sh] starting $BIN as uid=$(id -u) caps=$(getcap "$BIN" 2>/dev/null | sed "s|^$BIN ||" || echo none)"
exec "$BIN" "${@:2}"
