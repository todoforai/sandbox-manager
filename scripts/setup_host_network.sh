#!/bin/bash
# One-time host setup for running sandbox-manager as a non-root user.
# Bridge/NAT/forwarding are owned by sandbox-bridge.service (see systemd/install.sh).
set -e

echo "=== Sandbox Host Setup ==="

# 1. Bridge + NAT + forwarding (systemd-managed, self-healing)
"$(dirname "$0")/../systemd/install.sh"

# 2. Capabilities on sandbox-manager binary
BINARY="$(dirname "$0")/../target/release/sandbox-manager"
if [ -f "$BINARY" ]; then
    echo "Setting capabilities on sandbox-manager..."
    sudo setcap 'cap_net_admin,cap_net_raw+ep' "$BINARY"
    echo "✓ Capabilities set: $(getcap "$BINARY")"
else
    echo "⚠ Binary not found at $BINARY (build first: cargo build --release)"
fi

echo ""
echo "=== Done ==="
echo "Run sandbox-manager as normal user (no sudo needed):"
echo "  ./target/release/sandbox-manager"
