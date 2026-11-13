#!/bin/bash
# Keep sandbox VMs (Kata/Firecracker on cni-sandbox0, legacy br-sandbox) off
# our internal network. Without this a VM reaches the vSwitch (Dragonfly,
# GPU box) and every port on this host, because CNI masquerades VM traffic and
# the FORWARD/INPUT chains accept it.
#
# Policy for traffic entering from a VM bridge:
#   - reply direction of tracked flows: accept (host->VM SSH, VM's own public
#     flows). Original-direction packets of an older VM->internal flow still
#     hit the drop below, so installing this cuts existing sessions too.
#   - to a private/CGNAT/link-local address, routed or on this host: drop.
#     That covers the vSwitch, the gateway's sshd and services bound to
#     0.0.0.0 here. The host's public IP stays as reachable as from the
#     internet (ufw decides), and so does api.todofor.ai, where the in-VM
#     bridge connects.
#   - IPv6: VMs only have link-local; allow ICMPv6 (NDP), drop the rest.
# VM<->VM on the same bridge is L2 and never hits these hooks.
#
# Separate table + priority -10: a drop here is final regardless of the
# accept rules ufw/docker/CNI put in the iptables-nft tables. Idempotent,
# replaced atomically on each run.
set -euo pipefail
command -v nft >/dev/null || { echo "ERROR: nft not installed" >&2; exit 1; }

nft -f - <<'NFT'
table inet sandbox-egress
delete table inet sandbox-egress
table inet sandbox-egress {
	set vm_ifaces {
		type ifname
		elements = { "cni-sandbox0", "br-sandbox" }
	}
	set internal {
		type ipv4_addr
		flags interval
		elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
			     169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 }
	}
	chain forward {
		type filter hook forward priority filter - 10; policy accept;
		iifname != @vm_ifaces accept
		ct state established,related ct direction reply accept
		ip daddr @internal counter drop
		meta nfproto ipv6 counter drop
	}
	chain input {
		type filter hook input priority filter - 10; policy accept;
		iifname != @vm_ifaces accept
		ct state established,related ct direction reply accept
		ip daddr @internal counter drop
		meta l4proto ipv6-icmp accept
		meta nfproto ipv6 counter drop
	}
}
NFT
echo "[sandbox-egress] policy installed"
