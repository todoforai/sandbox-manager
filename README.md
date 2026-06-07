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

The bridge is the container **entrypoint**; the enrollment token is injected as
an env var (`ENROLL_TOKEN`). No MMDS, no guest `/init`, no SSH/vsock recovery
(use `containerd task exec`).

## Prereqs (host)

Run `../sandbox-manager/scripts/spike-kata-fc.sh` once (installs Kata + CNI,
devmapper pool, registers the `io.containerd.kata-fc.v2` runtime).

## Run

```sh
DRAGONFLY_URL=redis://... BACKEND_URL=https://api.todofor.ai \
BACKEND_ADMIN_API_KEY=... go run ./cmd/sandbox-manager
```
