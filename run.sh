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

# CAP_NET_ADMIN+CAP_NET_RAW so the binary can manage TAP devices without
# running as root. File caps are wiped on every rebuild — re-apply if missing.
if [ "$NODE_ENV" = "production" ] && ! getcap "$BIN" 2>/dev/null | grep -q cap_net_admin; then
    sudo setcap cap_net_admin,cap_net_raw=eip "$BIN"
fi

# Fallback: if caps still aren't set (e.g. no sudo), run via sudo so the process
# inherits root caps and can create TAPs / open /dev/kvm.
if [ "$NODE_ENV" = "production" ] && [ "$(id -u)" -ne 0 ] && ! getcap "$BIN" 2>/dev/null | grep -q cap_net_admin; then
    exec sudo -E "$BIN" "${@:2}"
fi
exec "$BIN" "${@:2}"
