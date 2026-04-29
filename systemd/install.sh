#!/bin/bash
# Install systemd units that own br-sandbox lifecycle.
# Run as root. Safe to re-run (units get reinstalled, daemon-reloaded, started).
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run as root (sudo $0)" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SRC_DIR/../scripts" && pwd)"
LIB_DIR="/usr/local/lib/sandbox-manager"
UNIT_DIR="/etc/systemd/system"

install -d "$LIB_DIR"
install -m 0755 "$SCRIPTS_DIR/ensure-bridge.sh" "$LIB_DIR/ensure-bridge.sh"

for unit in sandbox-bridge.service sandbox-bridge-recheck.service sandbox-bridge.timer; do
    install -m 0644 "$SRC_DIR/$unit" "$UNIT_DIR/$unit"
done

systemctl daemon-reload
systemctl enable --now sandbox-bridge.service sandbox-bridge.timer

echo
echo "Installed. Status:"
systemctl --no-pager status sandbox-bridge.service | head -n 5
ip -br link show br-sandbox
