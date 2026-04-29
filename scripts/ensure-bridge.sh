#!/bin/bash
# Idempotent bridge setup for sandbox VMs.
# Invoked by systemd (sandbox-bridge.service) on boot and after failures.
# Safe to run repeatedly: each step is a no-op if already applied.
set -euo pipefail

# Serialize concurrent runs (timer vs. service restart vs. manual invocation)
# to avoid racy check-then-act on `ip link add` / `iptables -A`.
LOCK=/run/sandbox-bridge.lock
exec 9>"$LOCK"
flock 9

BRIDGE="${BRIDGE_NAME:-br-sandbox}"
BRIDGE_IP="${BRIDGE_IP:-10.0.0.1/16}"
SUBNET="${NETWORK_SUBNET:-10.0.0.0/16}"

log() { echo "[ensure-bridge] $*"; }

# 1. Bridge device
if ip link show "$BRIDGE" &>/dev/null; then
    log "bridge $BRIDGE exists"
else
    log "creating bridge $BRIDGE"
    ip link add "$BRIDGE" type bridge
fi

# 2. Bridge IP — match the full CIDR (addr + prefix), fixed-string compare.
if ip -o -4 addr show dev "$BRIDGE" | awk '{print $4}' | grep -Fqx "$BRIDGE_IP"; then
    log "bridge IP $BRIDGE_IP present"
else
    log "assigning $BRIDGE_IP to $BRIDGE"
    ip addr add "$BRIDGE_IP" dev "$BRIDGE"
fi

# 3. Bridge UP
ip link set "$BRIDGE" up

# 4. IP forwarding
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
    log "enabling ip_forward"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

# 5. NAT
if ! iptables -t nat -C POSTROUTING -s "$SUBNET" -j MASQUERADE 2>/dev/null; then
    log "adding NAT rule for $SUBNET"
    iptables -t nat -A POSTROUTING -s "$SUBNET" -j MASQUERADE
fi

# 6. Inter-VM isolation
if ! iptables -C FORWARD -i "$BRIDGE" -o "$BRIDGE" -j DROP 2>/dev/null; then
    log "adding inter-VM DROP rule"
    iptables -A FORWARD -i "$BRIDGE" -o "$BRIDGE" -j DROP
fi

# 7. Re-enslave any orphan tap-* devices.
# If the bridge was deleted out from under running VMs and just got recreated,
# their TAPs are now master-less. Re-attach them so VMs regain connectivity.
for tap in $(ip -br link show type tun 2>/dev/null | awk '/^tap-/ {print $1}'); do
    master=$(ip -o link show dev "$tap" 2>/dev/null | grep -oP 'master \K\S+' || true)
    if [ "$master" != "$BRIDGE" ]; then
        log "re-attaching $tap to $BRIDGE"
        ip link set "$tap" master "$BRIDGE"
        ip link set "$tap" up
    fi
done

log "OK"
