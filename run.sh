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

BIN=target/release/sandbox-manager
[ -x "$BIN" ] || cargo build --release

# Prod needs CAP_NET_ADMIN for TAP creation and /dev/kvm access.
if [ "$NODE_ENV" = "production" ] && [ "$(id -u)" -ne 0 ]; then
    exec sudo -E "$BIN" "${@:2}"
fi
exec "$BIN" "${@:2}"
