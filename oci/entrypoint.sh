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
# A fresh ENROLL_TOKEN always means "enroll as a new device": the manager mints
# one per create, and the device it points at is the one the backend expects to
# come online. The home.img is persistent and may carry credentials from a
# previous device that the backend has since deleted/rotated — those would make
# the daemon fail with 4401. `login --token` refuses to overwrite existing
# creds ("Already logged in"), so we `logout` first to guarantee the new token
# wins. With no token (e.g. a plain reboot) we keep saved creds and reconnect.
set -eu

# Guest-local bridge log (see comment at exec). Truncate at boot so it can't
# grow across restarts; the rootfs snapshot is small and ephemeral.
BRIDGE_LOG=/var/log/todoforai-bridge.log
: > "$BRIDGE_LOG"

# NOTE: on success `login` falls through INTO the daemon (it does not return),
# so the exec below only runs on the no-token path or after a login failure.
# Both invocations therefore need the log redirect (see comment at exec).
if [ -n "${ENROLL_TOKEN:-}" ]; then
    /usr/local/bin/todoforai-bridge logout >/dev/null 2>&1 || true
    /usr/local/bin/todoforai-bridge login \
        ${DEVICE_NAME:+--device-name "$DEVICE_NAME"} \
        --token "$ENROLL_TOKEN" \
        >>"$BRIDGE_LOG" 2>&1 \
        || echo "enroll: login --token failed (continuing; daemon may start without creds)" >&2
fi

# Hand off to the daemon (no subcommand → loads saved creds and connects).
#
# Output MUST be redirected: the manager creates this task with cio.NullIO, so
# the container's stdout/stderr pipes have no reader. After ~64KB of daemon
# logs the pipe buffer fills and the bridge blocks forever in pipe_write —
# device goes "offline" while the VM looks healthy (live-debugged on prod).
# A guest-local log file both avoids the deadlock and keeps logs inspectable
# via exec.
exec /usr/local/bin/todoforai-bridge >>"$BRIDGE_LOG" 2>&1
