#!/bin/bash
# Per-exec network namespace for cli-lite sandboxes.
#
# Each invocation:
#   1. creates netns sb-<id>
#   2. creates veth pair (host: vl-<short>, peer: eth0 inside ns)
#   3. attaches host side to br-sandbox-lite
#   4. assigns a unique /16 IP from 10.2.0.0/16 (derived from id)
#   5. execs the supplied command inside the netns
#   6. always tears down on exit (trap)
#
# Used by sandbox-manager's lite backend instead of bwrap's --share-net.
# The egress policy lives in ensure-bridge-lite.sh (nftables).
#
# Usage: lite-netns.sh <sandbox-id> -- <cmd> [args...]
set -euo pipefail

[ "$#" -ge 3 ] || { echo "usage: $0 <id> -- <cmd> [args...]" >&2; exit 64; }
ID="$1"; shift
[ "$1" = "--" ] || { echo "expected -- after id" >&2; exit 64; }
shift

BRIDGE="${LITE_BRIDGE_NAME:-br-sandbox-lite}"
SUBNET_PREFIX="${LITE_SUBNET_PREFIX:-10.2}"   # IPs allocated as $PREFIX.x.y/16

# Short, collision-resistant tag for veth (kernel max 15 chars for ifname).
# 6 hex chars of sha1(id) — birthday collisions on the order of 16M.
TAG="$(printf '%s' "$ID" | sha1sum | cut -c1-6)"
NS="sb-${TAG}"
VETH_HOST="vl-${TAG}"
VETH_NS="eth0"

# Hash the id into the /16 host part (avoid .0, .1=gateway, .255).
HASH16=$((0x$(printf '%s' "$ID" | sha1sum | cut -c1-4)))
OCT3=$(( (HASH16 >> 8) & 0xff ))
OCT4=$(( HASH16 & 0xff ))
# Skip reserved low addresses and broadcast.
[ "$OCT3" = 0 ] && [ "$OCT4" -lt 2 ] && OCT4=2
[ "$OCT4" = 255 ] && OCT4=254
IP="${SUBNET_PREFIX}.${OCT3}.${OCT4}/16"
GATEWAY="${SUBNET_PREFIX}.0.1"

cleanup() {
    # Idempotent: each step swallowed individually so partial setup still tears down.
    ip link del "$VETH_HOST" 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
    rm -rf "/etc/netns/$NS" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Bridge must already exist (sandbox-bridge-lite.service).
ip link show "$BRIDGE" >/dev/null 2>&1 || {
    echo "lite-netns: bridge $BRIDGE missing — is sandbox-bridge-lite.service running?" >&2
    exit 69
}

# Wipe any leftover from a previous crashed exec with this id.
cleanup

ip netns add "$NS"
ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
ip link set "$VETH_HOST" master "$BRIDGE"
ip link set "$VETH_HOST" up
ip link set "$VETH_NS" netns "$NS"

ip -n "$NS" addr add "$IP" dev "$VETH_NS"
ip -n "$NS" link set "$VETH_NS" up
ip -n "$NS" link set lo up
ip -n "$NS" route add default via "$GATEWAY"

# DNS: ip netns exec auto-bind-mounts /etc/netns/<NS>/resolv.conf over
# /etc/resolv.conf inside the netns. The host's /etc/resolv.conf typically
# points at 127.0.0.53 (systemd-resolved stub), which is unreachable from
# the netns — use the *real* upstream list instead.
#
# Resolution order:
#   1. $LITE_DNS_SERVERS env (space-separated IPs) — explicit override
#   2. /run/systemd/resolve/resolv.conf — systemd-resolved publishes the
#      actual upstream resolvers here even when /etc/ points at the stub
#   3. 1.1.1.1 / 8.8.8.8 fallback — works on most hosts but some providers
#      (e.g. Hetzner) block UDP 53 to public resolvers, so 2 is preferred.
mkdir -p "/etc/netns/$NS"
{
    if [ -n "${LITE_DNS_SERVERS:-}" ]; then
        for ip in $LITE_DNS_SERVERS; do echo "nameserver $ip"; done
    elif [ -r /run/systemd/resolve/resolv.conf ]; then
        grep -E '^nameserver [0-9]' /run/systemd/resolve/resolv.conf | head -3
    else
        echo "nameserver 1.1.1.1"
        echo "nameserver 8.8.8.8"
    fi
    echo "options edns0 timeout:2 attempts:2"
} > "/etc/netns/$NS/resolv.conf"

# Run the command inside the netns. exec replaces this shell so trap fires
# only on signals, not on normal exit — but cleanup at end handles success.
set +e
ip netns exec "$NS" "$@"
rc=$?
set -e
exit "$rc"
