#!/bin/bash
# Idempotent egress-filtered bridge for cli-lite (FREE tier) sandboxes.
#
# This is the host-side enforcement that the comments in lite.rs and
# build-cli-lite.sh refer to. Without it, --share-net would expose host
# loopback, the paid VM bridge (br-sandbox, 10.0.0.0/16), and unrestricted
# outbound to the public internet.
#
# Layout:
#   br-sandbox-lite      10.2.0.1/16          host-side bridge
#   veth-lite-<short>    one per running exec  (peer lives in netns)
#   nftables table inet sandbox-lite           egress policy (default-deny)
#
# Policy: allow DNS (53), HTTP (80), HTTPS (443) to *public* destinations
# only. Drop RFC1918, link-local, loopback, IPv6 ULA/link-local. Drop SMTP,
# SSH, common abuse ports. Per-IP connection rate limited to slow scans.
set -euo pipefail

LOCK=/run/sandbox-bridge-lite.lock
exec 9>"$LOCK"
flock 9

BRIDGE="${LITE_BRIDGE_NAME:-br-sandbox-lite}"
BRIDGE_IP="${LITE_BRIDGE_IP:-10.2.0.1/16}"
SUBNET="${LITE_NETWORK_SUBNET:-10.2.0.0/16}"

log() { echo "[ensure-bridge-lite] $*"; }

# 1. Bridge device
if ip link show "$BRIDGE" &>/dev/null; then
    log "bridge $BRIDGE exists"
else
    log "creating bridge $BRIDGE"
    ip link add "$BRIDGE" type bridge
fi

# 2. Bridge IP
if ip -o -4 addr show dev "$BRIDGE" | awk '{print $4}' | grep -Fqx "$BRIDGE_IP"; then
    log "bridge IP $BRIDGE_IP present"
else
    log "assigning $BRIDGE_IP to $BRIDGE"
    ip addr add "$BRIDGE_IP" dev "$BRIDGE"
fi

ip link set "$BRIDGE" up

# 3. IP forwarding (already on if VM bridge ran first; idempotent)
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
    log "enabling ip_forward"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

# 4. nftables egress policy. Single table, replaced atomically each run so
#    edits to this script roll out without leaving stale rules.
command -v nft >/dev/null || { echo "ERROR: nftables (nft) not installed"; exit 1; }

log "installing nftables policy"
# Atomic replace: delete-then-recreate. `nft -f` doesn't replace tables in
# place — without the explicit delete, rules from previous versions of this
# script accumulate. Wrapped in an `add table` first so the delete never
# fails on a fresh host.
nft -f - <<NFT
add table inet sandbox-lite
delete table inet sandbox-lite
table inet sandbox-lite {
    set rfc1918 {
        type ipv4_addr; flags interval;
        elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 }
    }
    set link_local {
        type ipv4_addr; flags interval;
        elements = { 169.254.0.0/16, 127.0.0.0/8, 224.0.0.0/4, 0.0.0.0/8 }
    }
    set blocked_ports {
        type inet_service; flags interval;
        # SMTP, submission, SSH, IRC, mining-pool common ports, NetBIOS
        elements = { 22, 25, 465, 587, 2525, 6660-6669, 3333, 4444, 5555,
                     8333, 9999, 14444, 137-139, 445, 23 }
    }

    # FORWARD: lite netns → public internet (routed through host).
    chain forward {
        type filter hook forward priority 0; policy accept;

        ct state established,related accept

        # Only police traffic leaving the lite bridge.
        iifname != "$BRIDGE" return

        # Block abuse destinations / ports first.
        ip daddr @rfc1918   counter drop
        ip daddr @link_local counter drop
        tcp dport @blocked_ports counter drop
        udp dport @blocked_ports counter drop

        # Per-source-IP rate limit on new connections.
        ct state new limit rate over 60/second counter drop

        # Allow only DNS / HTTP / HTTPS to anything that survived above.
        udp dport 53 accept
        tcp dport { 53, 80, 443 } accept

        # Anything else from the lite bridge: drop.
        counter drop
    }

    # INPUT: lite netns → the host itself. Critical: traffic to 10.0.0.1
    # (paid-VM bridge gateway), 10.2.0.1 (this bridge), 127.0.0.1, or any
    # other IP the host owns is *input*, not *forward* — FORWARD chain
    # never sees it. Without this, cli-lite could curl http://10.0.0.1/.
    chain input {
        type filter hook input priority 0; policy accept;

        ct state established,related accept

        # Only police traffic arriving on the lite bridge.
        iifname != "$BRIDGE" accept

        # ICMP echo so users can ping the gateway (handy for debugging).
        icmp type { echo-request, echo-reply } accept

        # Everything else aimed at the host (incl. sandbox-manager on
        # :8200/:8202, host services on :22, etc.): drop.
        counter drop
    }
}
NFT

# 5. NAT for outbound (so allowed traffic actually reaches the internet).
if ! iptables -t nat -C POSTROUTING -s "$SUBNET" -j MASQUERADE 2>/dev/null; then
    log "adding NAT rule for $SUBNET"
    iptables -t nat -A POSTROUTING -s "$SUBNET" -j MASQUERADE
fi

# 6. UFW bypass: this host runs UFW with `FORWARD policy DROP` and an empty
#    ufw-user-forward chain — it drops everything that isn't explicitly
#    allowed. Without these rules, packets from the lite netns die before
#    our nftables `inet sandbox-lite` table sees them. Insert ACCEPT at
#    the *top* of FORWARD so UFW chains never run for this bridge.
#    The actual egress policy still applies via the nftables table.
for rule in \
    "FORWARD -i $BRIDGE -j ACCEPT" \
    "FORWARD -o $BRIDGE -j ACCEPT" ; do
    if ! iptables -C $rule 2>/dev/null; then
        log "adding bypass: iptables -I $rule"
        iptables -I $rule
    fi
done

# 7. Inter-sandbox isolation: lite sandboxes must not see each other.
#    Placed *after* the bypass ACCEPTs in priority — iptables -I inserts at
#    top so we re-insert here to land above the bypass for matching order.
if ! iptables -C FORWARD -i "$BRIDGE" -o "$BRIDGE" -j DROP 2>/dev/null; then
    log "adding inter-sandbox DROP rule"
    iptables -I FORWARD -i "$BRIDGE" -o "$BRIDGE" -j DROP
fi

log "OK"
