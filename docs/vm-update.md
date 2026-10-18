# Note: how a sandbox VM picks up a new bridge / rootfs

## TL;DR
A running VM's bridge self-updates like a desktop one: once idle it installs
the latest release and exits 0, and `oci/entrypoint.sh` (its supervisor —
it exports `INVOCATION_ID`, the signal `update.c` requires) starts the new
binary. Any other exit ends the container. The rootfs (and preinstalled CLIs)
still only change on delete + recreate; guest `reboot` keeps the old snapshot.

## The chain
1. The bridge binary is **baked into the rootfs** at image-build time:
   `assets/bridge.tag` → `scripts/sync-vendor.sh` (fetch + sha256 verify from
   `github.com/todoforai/bridge` releases) → `scripts/build-oci.sh` →
   `oci/Dockerfile` (`COPY todoforai-bridge`).
2. Tools with `preinstallCloud: true` in `tool_catalog.json` are installed into
   the same image. npm/bun package entries are grouped into `bun add -g`; system
   runtimes can declare `cloudInstallCmd`, `cloudAptPackages`, and
   `cloudVerifyCmd`. The Dockerfile is a generic executor, not a per-tool list.
   Each rootfs rebuild busts the bun layer (`BUN_CACHE_BUST`) so unpinned
   packages resolve latest.
3. `deploy.sh` (on every prod deploy) runs `build-oci.sh` with `IMPORT=1` so
   containerd gets the new image. `SKIP_ROOTFS=1` skips for binary-only rollouts.
4. tini is PID 1; the entrypoint runs the bridge in a loop that restarts it
   only on exit 0 (an applied self-update). The pin sets the version a fresh
   VM boots with, so keep it near the latest release.

## How a running VM picks up the new image
- **Explicit update**: backend `DeviceService.updateBridge` for a sandbox device
  calls `CloudDeviceService.recreateCloudVm` → delete sandbox + `ensureCloudVm({wake:true})`.
  home.img + Device row persist; machine-id re-enrolls onto the same device.
- **Death / idle reaper / revoke**: manager marks dead slots `error`, backend
  `ensureCloudVm` creates a fresh VM on the **current** rootfs.
- Guest `reboot` does **not** swap the rootfs snapshot — do not use it for updates.

So: bump `assets/bridge.tag` (or catalog) → merge to `prod` (deploy rebuilds +
imports rootfs) → call device update (or wait for next natural recreate) on
each VM. New VMs always get the current image.

## Deliberately rejected alternatives
- **Manager-side restart/recreate** — wrong layer; recreate is the backend's
  job. Adding it here fights the existing separation.
- **Unbounded entrypoint loop** (`while :; do bridge; done`; the shipped loop
  restarts only on exit 0 and exits with any failure's status) — dangerous:
  a crash/bad-binary becomes a hot crash-loop (100% CPU, log spam, a botched
  self-update respawns forever). If in-VM hot-update is ever wanted, it must be
  a *bounded* loop (exponential backoff + crash-loop cap that exits after N
  fast failures so the manager's dead-VM reconcile catches a broken binary) —
  not the naive loop.

## Context
Surfaced while fixing the `https://api.todofor.ai:80` vault URL bug: prod VMs
ran bridge v1.4.3 (pre-`2873602e`). Fixed by bumping `assets/bridge.tag`
v1.4.3 → v1.4.5; existing VMs heal via the recreate path above.
