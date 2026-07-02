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

# Best-effort: mount the user's todofor.ai cloud workspace as a FUSE filesystem
# so agent shell commands can read/write cloud files directly at a stable path.
# The slim rclone (COPY'd by the Dockerfile) + fusermount3 (fuse3 apt pkg) ship
# in the image; Kata gives the guest root + a FUSE-capable kernel. Read+write is
# byte-exact (rclone hits storage-manager, not the utf-8 content endpoints). The
# mount is derived from the bridge's own device credentials
# (deviceId+deviceSecret → dst_ session token → user API key) so no extra
# secrets are injected. MUST NOT block or fail the boot — a broken mount would
# make the device look offline for a non-essential feature, so everything here
# is wrapped and the daemon starts regardless.
mount_cloud() {
    command -v rclone >/dev/null 2>&1 || { echo "mount: rclone not installed, skipping" >&2; return; }
    creds=$HOME/.config/todoforai/credentials.json
    [ -r "$creds" ] || { echo "mount: no credentials.json, skipping" >&2; return; }

    device_id=$(jq -r '.deviceId // empty' "$creds")
    device_secret=$(jq -r '.deviceSecret // empty' "$creds")
    # API URL: prefer canonical apiUrl, else reconstruct from backendHost
    # (http for localhost/127.0.0.1, https otherwise) — mirrors the tfa-* CLIs.
    api_url=$(jq -r '
        if (.apiUrl // "") != "" then .apiUrl
        elif (.backendHost // "") != "" then
            (if (.backendHost == "localhost" or .backendHost == "127.0.0.1") then "http://" else "https://" end) + .backendHost
        else "" end' "$creds")
    [ -n "$device_id" ] && [ -n "$device_secret" ] && [ -n "$api_url" ] || {
        echo "mount: incomplete credentials, skipping" >&2; return; }

    # deviceId+secret → short-lived dst_ session token (accepted on /dst/v1).
    dst=$(curl -fsS -X POST "$api_url/api/v1/cli/device/token" \
        -H 'Content-Type: application/json' \
        -d "{\"deviceId\":\"$device_id\",\"secret\":\"$device_secret\"}" \
        | jq -r '.token // empty')
    [ -n "$dst" ] || { echo "mount: device token exchange failed" >&2; return; }

    # Reuse a named API key across boots (GET first); create only if missing —
    # POST is NOT idempotent and would spam one key per boot.
    key=$(curl -fsS "$api_url/dst/v1/apikeys/rclone-sandbox-mount" \
        -H "x-api-key: $dst" | jq -r '.id // empty')
    [ -n "$key" ] || key=$(curl -fsS -X POST "$api_url/dst/v1/apikeys" \
        -H "x-api-key: $dst" -H 'Content-Type: application/json' \
        -d '{"name":"rclone-sandbox-mount"}' | jq -r '.id // empty')
    [ -n "$key" ] || { echo "mount: could not obtain API key" >&2; return; }

    # Non-interactive rclone remote pinned to the same API URL.
    rclone config create todoforai todoforai \
        api_key="$key" url="$api_url" --non-interactive >/dev/null 2>&1 || {
        echo "mount: rclone config failed" >&2; return; }

    mnt=$HOME/.todoforai/mnt/todoforai
    mkdir -p "$mnt"
    mountpoint -q "$mnt" && { echo "mount: already mounted at $mnt" >&2; return; }
    rclone mount todoforai: "$mnt" \
        --vfs-cache-mode full --vfs-fast-fingerprint --no-modtime \
        --attr-timeout 1h --vfs-cache-max-size 400M \
        --daemon --log-level INFO --log-file "$BRIDGE_LOG" \
        && echo "mount: cloud workspace at $mnt" >&2 \
        || echo "mount: rclone mount failed" >&2
}
mount_cloud || echo "mount: skipped (unexpected error)" >&2

# Hand off to the daemon (no subcommand → loads saved creds and connects).
#
# Output MUST be redirected: the manager creates this task with cio.NullIO, so
# the container's stdout/stderr pipes have no reader. After ~64KB of daemon
# logs the pipe buffer fills and the bridge blocks forever in pipe_write —
# device goes "offline" while the VM looks healthy (live-debugged on prod).
# A guest-local log file both avoids the deadlock and keeps logs inspectable
# via exec.
exec /usr/local/bin/todoforai-bridge >>"$BRIDGE_LOG" 2>&1
