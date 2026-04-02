#!/bin/bash
# One-time host network setup for sandbox VMs (requires sudo)
# After this, sandbox-manager runs without root using CAP_NET_ADMIN.
set -e

BRIDGE="br-sandbox"
BRIDGE_IP="10.0.0.1/16"
SUBNET="10.0.0.0/16"

echo "=== Sandbox Host Network Setup ==="

# 1. Bridge
if ip link show "$BRIDGE" &>/dev/null; then
    echo "✓ Bridge $BRIDGE exists"
else
    echo "Creating bridge $BRIDGE..."
    sudo ip link add "$BRIDGE" type bridge
    sudo ip addr add "$BRIDGE_IP" dev "$BRIDGE"
    sudo ip link set "$BRIDGE" up
    echo "✓ Bridge $BRIDGE created"
fi

# 2. NAT
if sudo iptables -t nat -C POSTROUTING -s "$SUBNET" -j MASQUERADE 2>/dev/null; then
    echo "✓ NAT rule exists"
else
    echo "Adding NAT rule..."
    sudo iptables -t nat -A POSTROUTING -s "$SUBNET" -j MASQUERADE
    echo "✓ NAT rule added"
fi

# 3. IP forwarding
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    echo "✓ IP forwarding enabled"
else
    echo "Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1
    echo "✓ IP forwarding enabled"
fi

# 4. Inter-VM isolation
if sudo iptables -C FORWARD -i "$BRIDGE" -o "$BRIDGE" -j DROP 2>/dev/null; then
    echo "✓ VM isolation rule exists"
else
    echo "Adding VM isolation rule..."
    sudo iptables -A FORWARD -i "$BRIDGE" -o "$BRIDGE" -j DROP
    echo "✓ VM isolation rule added"
fi

# 5. Capabilities on sandbox-manager binary
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
