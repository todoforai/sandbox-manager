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
install -m 0755 "$SCRIPTS_DIR/ensure-bridge.sh"      "$LIB_DIR/ensure-bridge.sh"
install -m 0755 "$SCRIPTS_DIR/ensure-bridge-lite.sh" "$LIB_DIR/ensure-bridge-lite.sh"
install -m 0755 "$SCRIPTS_DIR/lite-netns.sh"         "$LIB_DIR/lite-netns.sh"
install -m 0755 "$SCRIPTS_DIR/lite-mount-home.sh"    "$LIB_DIR/lite-mount-home.sh"

# Sudoers rule for lite-mount-home.sh. sandbox-manager invokes this via
# `sudo -n` on every Lite provision/destroy. On prod the manager already
# runs as root and sudo is a no-op fast-path; on dev (uid=master) this
# rule is what makes loop-mount work without splitting the code path.
#
# SANDBOX_MANAGER_USER env override lets ops scope the rule to a non-default
# user (e.g. a dedicated `sandbox` system user). Defaults to `master` on
# dev hosts and is irrelevant on prod (root needs no sudoers entry).
SBM_USER="${SANDBOX_MANAGER_USER:-master}"
SUDOERS_FILE="/etc/sudoers.d/sandbox-manager-lite-mount"
cat > "$SUDOERS_FILE" <<EOF
# Managed by sandbox-manager/systemd/install.sh — do not edit by hand.
$SBM_USER ALL=(root) NOPASSWD: $LIB_DIR/lite-mount-home.sh attach *, $LIB_DIR/lite-mount-home.sh detach *
EOF
chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null || {
    rm -f "$SUDOERS_FILE"
    echo "ERROR: sudoers rule failed visudo check; removed" >&2
    exit 1
}

for unit in sandbox-bridge.service sandbox-bridge-recheck.service sandbox-bridge.timer \
            sandbox-bridge-lite.service; do
    install -m 0644 "$SRC_DIR/$unit" "$UNIT_DIR/$unit"
done

systemctl daemon-reload
systemctl enable --now sandbox-bridge.service sandbox-bridge.timer sandbox-bridge-lite.service

echo
echo "Installed. Status:"
systemctl --no-pager status sandbox-bridge.service      | head -n 5
systemctl --no-pager status sandbox-bridge-lite.service | head -n 5
ip -br link show br-sandbox
ip -br link show br-sandbox-lite
