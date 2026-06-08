# sandbox-manager (Go)

A thin VM factory: turns an HTTP request into a Firecracker microVM (via
**Kata Containers** on stock **containerd**) with **CNI** networking and a
persistent per-user `home.img` drive.

This replaces the old Rust service that hand-managed Firecracker processes,
TAP/IP networking, MMDS enrollment and crash reconciliation. Kata + containerd
+ CNI own all of that now; this service is just auth, quota, inventory and the
containerd glue.

## Architecture

```
HTTP API ──> service (auth + quota, 1 sandbox/user)
                │
                ├─> containerd client ── runtime io.containerd.kata-fc.v2 ──> Firecracker microVM
                │        (NewContainer/NewTask/Exec, devmapper snapshotter)
                ├─> go-cni ──────────────────────────────────────────────> guest networking
                ├─> Redis ───────────────────────────────────────────────> inventory + events (backend subscribes)
                └─> backend client ──────────────────────────────────────> mint enrollment token
```

The bridge is the container **entrypoint** (`oci/entrypoint.sh`): on first boot
it redeems the `ENROLL_TOKEN` env var via `todoforai-bridge login --token`,
saving creds onto the persistent `home.img`, then execs the daemon. Idempotent
on restart. No MMDS, no guest `/init`, no SSH/vsock recovery (use
`containerd task exec`).

## Building the sandbox rootfs (OCI image)

The guest userland is a normal OCI image (`oci/Dockerfile`) — Kata ships the
guest kernel, so there's nothing else to build. The image bundles the toolset
(jq, rg, fd, gh, vault, bun, …), the tfa-* catalog CLIs, and the bridge.

```sh
IMPORT=1 scripts/build-oci.sh                          # -> sandbox-rootfs:dev, loaded into containerd
IMAGE=registry/foo/sandbox-rootfs:v1 PUSH=1 scripts/build-oci.sh
```

In dev there's no registry, so the manager can't pull `sandbox-rootfs:dev`
(it would hit Docker Hub → "pull access denied"). `IMPORT=1` loads the freshly
built image straight into containerd's namespace, which is where the manager
looks. For prod, `PUSH=1` to a registry and point the service at it with
`SANDBOX_ROOTFS_IMAGE`.

## Prereqs (host)

On a fresh machine, run these once (both idempotent):

```sh
sudo ./scripts/spike-kata-fc.sh   # Kata + Firecracker, CNI, devmapper pool,
                                  # registers io.containerd.kata-fc.v2
./scripts/setup-host.sh           # NOPASSWD sudoers rule + /data/user-homes
IMPORT=1 ./scripts/build-oci.sh   # build sandbox-rootfs:dev + load into containerd
```

`setup-host.sh` is what makes the box reproducible: the service must run as
root (containerd.sock, losetup, kata-runtime, ip netns, firecracker), but PM2
runs as your user, so it installs a NOPASSWD sudoers rule letting PM2 launch
the manager via `sudo`. The rule is generated (the binary path is repo-/user-
specific), so it's not committed — re-run `setup-host.sh` after moving the repo
or on each new PC.

## Run

Config lives in `.env` (prod) / `.env.development` (dev); the binary loads it
from its cwd. Start via PM2 — it builds the binary and launches it as root:

```sh
pm2 start ecosystem.config.js --only sandbox-manager
pm2 logs sandbox-manager
```

To run the binary directly (e.g. debugging), it still needs root:

```sh
sudo NODE_ENV=development ./sandbox-manager
```
