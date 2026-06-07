#!/bin/sh
# Sandbox entrypoint. Replaces the old Firecracker /init (MMDS fetch + network
# setup) — Kata's guest agent already gave us a configured, networked rootfs.
#
# Contract with the manager:
#   ENROLL_TOKEN  (optional) — one-shot enrollment token, injected via the OCI
#                  env on first boot. Redeemed into ~/.config/todoforai/
#                  credentials.json, which lives on the persistent home.img.
#   DEVICE_NAME   (optional) — friendly name for the Device row.
#
# Idempotent across restarts: `login --token` no-ops when creds already exist,
# so on a reboot with a populated home.img we skip straight to the daemon.
set -eu

if [ -n "${ENROLL_TOKEN:-}" ]; then
    /usr/local/bin/todoforai-bridge login \
        ${DEVICE_NAME:+--device-name "$DEVICE_NAME"} \
        --token "$ENROLL_TOKEN" \
        || echo "enroll: login --token failed (continuing; daemon will use any saved creds)" >&2
fi

# Hand off to the daemon (no subcommand → loads saved creds and connects).
exec /usr/local/bin/todoforai-bridge
