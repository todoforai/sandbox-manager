# Note: how a sandbox VM picks up a new bridge / rootfs

## TL;DR
There is **no in-place self-update inside a running VM** — and that's by design.
A VM gets a new bridge by being **recreated** onto a freshly-built rootfs. The
recreate path is already automatic and safe; nothing extra is needed.

## The chain
1. The bridge binary is **baked into the rootfs** at image-build time:
   `assets/bridge.tag` → `scripts/sync-vendor.sh` (fetch + sha256 verify from
   `github.com/todoforai/bridge` releases) → `scripts/build-oci.sh` →
   `oci/Dockerfile` (`COPY todoforai-bridge`).
2. The guest entrypoint ends in `exec /usr/local/bin/todoforai-bridge`
   (`oci/entrypoint.sh`), so the bridge **is** the guest's pid 1 — no in-guest
   supervisor, hence no `kill -TERM`-based self-update (that mechanism in the
   bridge assumes a systemd/launchd/shell-loop parent that this sandbox
   intentionally dropped).

## Why a running VM still heals
- `Manager.IsLive` (`internal/vm/manager.go`) reports a VM dead when its
  containerd task isn't `Running`.
- `Service.staleDead` + `Reconcile`/`ReconcileLoop` (every 30s,
  `cmd/sandbox-manager/main.go`) mark a dead-but-active record `error` and
  release its quota slot. `List` also surfaces dead VMs as `error`
  (read-only).
- **The backend owns recreate**: it reacts to `error`/`List` and calls the
  manager's `Create` again, which boots a fresh VM on the **current** rootfs.
  The manager deliberately does NOT auto-restart/recreate — that would
  duplicate the backend's policy ownership.

So: bump `assets/bridge.tag` → merge to `prod` (CI `deploy.yml` rebuilds the
rootfs) → existing VMs pick up the new bridge on their **next recreate**
(death/reboot/backend-driven re-create). No manager change required.

## Deliberately rejected alternatives
- **Manager-side restart/recreate** — wrong layer; recreate is the backend's
  job. Adding it here fights the existing separation.
- **Unbounded entrypoint loop** (`while :; do bridge; done`) — dangerous:
  a crash/bad-binary becomes a hot crash-loop (100% CPU, log spam, a botched
  self-update respawns forever). If in-VM hot-update is ever wanted, it must be
  a *bounded* loop (exponential backoff + crash-loop cap that exits after N
  fast failures so the manager's dead-VM reconcile catches a broken binary) —
  not the naive loop.

## Context
Surfaced while fixing the `https://api.todofor.ai:80` vault URL bug: prod VMs
ran bridge v1.4.3 (pre-`2873602e`). Fixed by bumping `assets/bridge.tag`
v1.4.3 → v1.4.5; existing VMs heal via the recreate path above.
