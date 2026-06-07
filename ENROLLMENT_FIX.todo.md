# Plan: fix sandbox device enrollment (bridge → backend)

## Context
The sandbox-manager (Go) boots a Kata/Firecracker microVM whose entrypoint
(`oci/entrypoint.sh`) runs `todoforai-bridge login --token $ENROLL_TOKEN
--device-name $DEVICE_NAME` then execs the bridge daemon. The bridge redeems
the token against the backend's **Noise** endpoint and saves device credentials
to `~/.config/todoforai/` on the persistent `home.img`.

Enrollment contract (already correct on both ends):
- Manager mints:  `POST {BACKEND_URL}/admin/v1/enroll/mint` (X-API-Key) → `{token}`
  — `internal/backend/backend.go:33`
- Bridge redeems: Noise RPC `{"type":"cli.enroll.redeem","payload":{token,deviceName,identity}}`
  — `bridge/subcmd.c:66` → backend `noise/dispatcher.ts:75`

## The bug
The bridge resolves the backend Noise address as:
`--host > NOISE_BACKEND_HOST env > saved creds > prod default`
(`bridge/subcmd.c:24` resolve_backend_addr).

The manager injects ONLY `ENROLL_TOKEN` + `DEVICE_NAME` into the VM
(`internal/vm/manager.go:109`). It does NOT inject `NOISE_BACKEND_HOST` /
`NOISE_BACKEND_PORT`. So the VM falls back to the **prod** Noise default — on a
dev box it enrolls against prod, not the local backend. The old Rust system
injected `NOISE_BACKEND_HOST` (git history: "export only NOISE_BACKEND_HOST");
the Go rewrite dropped it.

The VM reaches the host at the CNI bridge gateway **10.88.0.1**. The dev backend
binds Noise on `0.0.0.0` (`backend/.env.development:47 NOISE_BIND_HOST=0.0.0.0`).

## Tasks

### 1. Add Noise-endpoint config to the manager
File: `internal/config/config.go`
- Add fields `NoiseBackendHost string`, `NoiseBackendPort string`.
- Load from env `NOISE_BACKEND_HOST` / `NOISE_BACKEND_PORT` (no hard default —
  empty means "let the bridge use its prod default", which is correct for prod).

### 2. Inject them into the VM env
File: `internal/vm/manager.go` (Create, ~line 109, where `env` is built)
- When set, append `NOISE_BACKEND_HOST=<...>` and `NOISE_BACKEND_PORT=<...>` to
  the OCI env list (alongside ENROLL_TOKEN / DEVICE_NAME).

### 3. Set dev values in env files
File: `sandbox-manager/.env.development`
- `NOISE_BACKEND_HOST=10.88.0.1`  (host as seen from the VM via cni-sandbox0)
- `NOISE_BACKEND_PORT=14100`  (CONFIRMED: dev backend PORT=4000, Noise = PORT+10100
  = 14100, verified listening on 0.0.0.0; matches the old MMDS dev value).
File: `sandbox-manager/.env` (prod)
- Leave `NOISE_BACKEND_HOST`/`PORT` UNSET so the bridge uses its prod default,
  OR set them explicitly to the prod Noise host:port if the VM can't resolve
  the prod hostname via DNS (it can — DNS works, proven). Prefer leaving unset.

### 4. Confirm the dev backend Noise endpoint is reachable from the VM
- Backend must bind Noise on `0.0.0.0:<port>` (already does in dev).
- From a booted sandbox, `nc -z 10.88.0.1 <port>` (or the bridge's own connect)
  must succeed. The firewall/NAT already allows VM→host (egress proven).

## Verification (end-to-end)
1. `pm2 restart sandbox-manager` (picks up new env).
2. Ensure local backend + dragonfly are up.
3. Create a sandbox via a real session (frontend "Add hosted desktop", or
   `POST /sandbox` with a valid bearer).
4. Inside the VM (via `POST /sandbox/{id}/exec`):
   - `cat ~/.config/todoforai/credentials.json` → contains device_id, device_name.
   - bridge daemon process is running and connected (check its log/stderr).
5. Backend side: a Device row exists for the user with that device_id; the
   sandbox's device shows online.
6. Reboot the VM (delete+recreate is NOT a reboot; use stop/start if supported,
   else recreate with the SAME home.img): `login --token` no-ops, daemon
   reconnects with saved creds → idempotency confirmed.

## Out of scope / already correct
- entrypoint.sh start sequence (correct).
- bridge login/redeem flags (correct).
- mint HTTP contract (correct).
- creds persistence on home.img (correct).
