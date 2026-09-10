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
# A fresh ENROLL_TOKEN always means "re-enroll": the manager mints one per
# create. Thanks to the persistent machine-id below, the redeem upserts onto
# the user's existing Device row (same device id, rotated secret) — but the
# rotation invalidates any credentials.json left on the home.img, which would
# make the daemon fail with 4401. `login --token` refuses to overwrite
# existing creds ("Already logged in"), so we `logout` first to guarantee the
# new token wins. With no token (e.g. a plain reboot) we keep saved creds and
# reconnect.
set -eu

# Guest-local bridge log (see comment at exec). Truncate at boot so it can't
# grow across restarts; the rootfs snapshot is small and ephemeral.
BRIDGE_LOG=/var/log/todoforai-bridge.log
: > "$BRIDGE_LOG"

# Stable device identity: the rootfs (and its /etc/machine-id) is shared by
# every VM, but the home.img is per-user and persistent. Keep a machine-id
# there and install it as /etc/machine-id each boot, so the bridge's
# identity.machine_id is stable across stop→wake cycles and the backend
# re-enrolls onto the SAME Device row (device ids in agentSettings stay valid).
MID_FILE=${HOME:-/root}/.todoforai/machine-id
if ! grep -Eqs '^[0-9a-f]{32}$' "$MID_FILE"; then
    # Missing or corrupt (e.g. crash mid-write) — regenerate atomically.
    mkdir -p "$(dirname "$MID_FILE")"
    tr -d '-' < /proc/sys/kernel/random/uuid > "$MID_FILE.tmp"
    mv "$MID_FILE.tmp" "$MID_FILE"
fi
cat "$MID_FILE" > /etc/machine-id || echo "machine-id: could not install to /etc" >&2

# Fresh enrollment must not reuse a stale credentials.json (see NOTE above the
# login); done before the mount waiter starts so it can't pick the stale one.
[ -n "${ENROLL_TOKEN:-}" ] && { /usr/local/bin/todoforai-bridge logout >/dev/null 2>&1 || true; }

# X (xurl) OAuth2 needs a registered developer app or the authorize URL goes
# out with client_id= empty. Register ours on the persistent home so the
# catalog's plain `xurl auth oauth2` works. Idempotent: update if present.
# Unset afterwards: the bridge is exec'd below and every agent shell inherits
# its env (the secret still lives in ~/.xurl, 0600 — this is hygiene).
if [ -n "${X_CLIENT_ID:-}" ] && command -v xurl >/dev/null 2>&1; then
    { xurl auth apps update todoforai --client-id "$X_CLIENT_ID" --client-secret "${X_CLIENT_SECRET:-}" \
        || xurl auth apps add todoforai --client-id "$X_CLIENT_ID" --client-secret "${X_CLIENT_SECRET:-}" \
            --redirect-uri http://localhost:8080/callback; } >/dev/null 2>&1 \
        && xurl auth default todoforai >/dev/null 2>&1 \
        || echo "xurl: app registration failed" >&2
fi
unset X_CLIENT_ID X_CLIENT_SECRET

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
# The OCI spec grants /dev/fuse (node + device-cgroup allow), but the Kata
# runtime strips Linux.Resources.Devices before handing the spec to the guest
# agent, which then builds its own default whitelist without fuse. The guest
# is root in its own cgroup, so add the rule here (guest-scoped, cgroup v1).
mnt=$HOME/.todoforai/mnt/todoforai

allow_fuse() {
    python3 -c 'import os; os.close(os.open("/dev/fuse", os.O_RDWR))' 2>/dev/null && return
    cg=$(mktemp -d)
    mount -t cgroup -o devices none "$cg" || return
    echo 'c 10:229 rwm' > "$cg$(sed -n 's/^[0-9]*:devices://p' /proc/self/cgroup)/devices.allow"; rc=$?
    umount "$cg"; rmdir "$cg"
    return $rc
}

mount_cloud() {
    command -v rclone >/dev/null 2>&1 || { echo "mount: rclone not installed, skipping" >&2; return; }
    allow_fuse || echo "mount: could not allow /dev/fuse in device cgroup" >&2
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

    # Hand rclone the durable device credentials, not a one-shot dst_ token:
    # the backend mints a dst_ token itself and re-mints it at half TTL (and
    # on 401), so the mount survives past the 24h token lifetime. The secret
    # is already readable in credentials.json by everything in the sandbox,
    # so this widens nothing; dst_ tokens still can't mint durable API keys.
    rclone config create todoforai todoforai \
        device_id="$device_id" device_secret="$device_secret" url="$api_url" \
        --non-interactive >/dev/null 2>&1 || {
        echo "mount: rclone config failed" >&2; return; }

    mkdir -p "$mnt"
    rclone mount todoforai: "$mnt" \
        --vfs-cache-mode full --vfs-fast-fingerprint --no-modtime \
        --attr-timeout 1h --vfs-cache-max-size 400M \
        --daemon --log-level INFO --log-file "$BRIDGE_LOG" \
        && echo "mount: cloud workspace at $mnt" >&2 \
        || echo "mount: rclone mount failed" >&2
}
# Backgrounded: on a fresh VM `login --token` below never returns (it becomes
# the daemon), and usable credentials only exist once it has enrolled (logout
# may leave a file with an empty deviceSecret). Retry with backoff until
# mounted — slow enrollment or a backend blip must not lose the mount for the
# VM's lifetime. stderr is /dev/null (cio.NullIO): log to the guest.
{
    delay=1
    until mountpoint -q "$mnt"; do
        [ "$(jq -r '.deviceSecret // empty' "$HOME/.config/todoforai/credentials.json" 2>/dev/null)" ] \
            && { mount_cloud || echo "mount: skipped (unexpected error)" >&2; }
        sleep $delay; [ $delay -lt 60 ] && delay=$((delay * 2))
    done
} 2>>"$BRIDGE_LOG" &

# NOTE: on success `login` falls through INTO the daemon (it does not return),
# so the exec below only runs on the no-token path or after a login failure.
# Both invocations therefore need the log redirect (see comment at exec).
if [ -n "${ENROLL_TOKEN:-}" ]; then
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
