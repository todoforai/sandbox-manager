# Cloud SSH (native SSH into a user's cloud VM)

Off by default. Enabled only when `SSH_PUBLIC_HOST`, `SSH_PORT_START` and
`SSH_PORT_END` are all set (a partial set fails startup). No listeners open
until the backend prepares a sandbox.

## Flow

1. Backend (admin bearer) calls `POST /sandbox/{id}/ssh` (no body).
2. Manager runs `/usr/local/sbin/cloud-ssh-setup <SSH_AUTH_URL>` in the guest
   over containerd exec (idempotent, serialized per sandbox, 25s bound). It
   creates or reuses the per-user host key and the workspace home, starts the
   dedicated sshd, waits until it listens on :22, and prints the host public key.
3. Manager opens (or reuses) one TCP port from the range for that sandbox,
   relaying only to `<sandbox IP>:22`. It stores the port in Redis
   (`sandbox:ssh-port:<id>`) so a manager restart reopens the same port.
4. Response `200`:
   `{"host","port","hostKey":"ssh-ed25519 <b64>","user":"workspace","cloudDeviceId"}`.
   `hostKey` comes from inside the VM over exec; it is never keyscanned.
   Errors: `404` (relay not configured, or sandbox not running or without
   `device_id`), `403` (non-admin), `503` (guest sshd not ready, port range
   exhausted, or the port could not be persisted).

Prepare does not update `last_activity`.

## Guest

- User `workspace` (uid 1000) has home `/workspace`, no sudo, and password
  hash `*`. That hash rejects passwords but is not "locked", which matters
  because sshd with `UsePAM no` refuses locked accounts even for pubkey.
- `/workspace` is a bind mount of `/root/.todoforai/ssh-workspace` (0700,
  owned by workspace) on the persistent home.img. `/root` permissions are
  left unchanged (home.img root is 0755). Secrets are protected by their own
  modes: `credentials.json` is 0600 and `ssh-host/` is 0700 root.
- Host key: `/root/.todoforai/ssh-host/` (0700 root). It is per user, persists
  on home.img, and is outside the workspace. The image's generated host keys
  are deleted at build time.
- sshd config `/etc/ssh/cloud-sshd_config`: `AllowUsers workspace`, ed25519
  pubkey only, no password or keyboard-interactive, `DisableForwarding yes`
  (no TCP, agent, X11 or tunnel forwarding), internal-sftp (so scp and SFTP
  work; rsync is installed), `LoginGraceTime 20`, and ClientAlive 30s×3.
- No static authorized_keys (`AuthorizedKeysFile none`). The
  `AuthorizedKeysCommand /usr/local/libexec/cloud-ssh-authorized-key %t %k`
  runs as root. It skips any non-ed25519 key before making an HTTP call, then
  POSTs `{deviceId, secret, key}` over stdin (never argv) to `SSH_AUTH_URL`.
  Credentials come from `/root/.config/todoforai/credentials.json`: the
  top-level `deviceId`/`deviceSecret`, or `sets.dev` on dev VMs. The key is
  emitted only when the backend returns exactly that key; empty means deny.
  There is no cache, so revocation applies to the next connection.

## `ssh_connections`

`GET /sandbox`, `GET /sandbox/{id}` and the admin list include
`ssh_connections` (omitted when 0). It counts relay sessions open for at least
30s. That is longer than `LoginGraceTime`, so unauthenticated TCP never
counts. The value is live-only: it is never persisted and is 0 after a
manager restart. The backend idle reaper treats `> 0` as busy, so an open
authenticated terminal keeps the VM awake by design. Each sandbox is capped at
8 concurrent relay connections.

## Lifecycle

- Listeners exist only for `running` sandboxes. Delete and teardown close the
  listener and all of its active connections before the VM is destroyed.
- Reconcile (at startup and every 30s) closes listeners for non-running
  sandboxes or changed IPs. It reopens remembered ports for running ones and
  re-checks state afterwards, so a concurrent delete cannot leave a listener.
- A VM reboot kills guest sshd. The next backend prepare restarts it.

## Ops

- Set the three env vars and open exactly `SSH_PORT_START-SSH_PORT_END/tcp`
  inbound on the host firewall. The manager binds these ports on all
  interfaces.
- SSH to the cloud does NOT isolate it from the PC: any paired PC key the
  backend approves gets a shell as `workspace`. The shell can still reach the
  network, and the cloud's own credentials stay root-only. Only the VM
  boundary and the non-root user isolate the session. Treat the session as the
  user's.
- Known limitation: revoking or unpairing a PC blocks new logins
  immediately, but already-established sessions continue until they
  disconnect. There is no kill API.
- Local guest test: `scripts/test-cloud-ssh.sh` (docker; touches no VM).
