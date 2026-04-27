# Sandbox Manager

High-performance VM sandbox system using Firecracker microVMs with bridge PTY relay.

## Role in the platform

Sandbox Manager is a **VM factory**. Its job is narrow: produce Firecracker microVMs that come up with the bridge already running and connected to the backend. It does **not** manage networking between sandboxes, SSH keys, certs, user capabilities, or language runtimes — all of that is configured by the AI at the user's request via commands through the bridge.

See [`ARCHITECTURE_BRIDGE_MACHINES.md`](../ARCHITECTURE_BRIDGE_MACHINES.md) for the overall model: bridges are islands by default, the AI acts as a sysadmin, capabilities are additive.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Sandbox Manager (Rust)                                          │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ REST API (Axum)                                          │  │
│  │  POST   /sandbox              Create sandbox             │  │
│  │  GET    /sandbox/:id          Get sandbox info           │  │
│  │  DELETE /sandbox/:id          Delete sandbox             │  │
│  │  POST   /sandbox/:id/exec     Execute command            │  │
│  │  POST   /sandbox/:id/pause    Pause VM                   │  │
│  │  POST   /sandbox/:id/resume   Resume VM                  │  │
│  │  WS     /sandbox/:id/tty      Terminal WebSocket         │  │
│  │  GET    /templates            List templates             │  │
│  │  GET    /stats                Get statistics             │  │
│  └──────────────────────────────────────────────────────────┘  │
│                           │                                      │
│                           ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ VmManager                                                │  │
│  │  • Session tracking (DashMap)                            │  │
│  │  • Firecracker process management                        │  │
│  │  • Network allocation                                    │  │
│  │  • Idle cleanup                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│         │                    │                    │              │
│         ▼                    ▼                    ▼              │
│  ┌─────────────┐      ┌─────────────┐      ┌──────────────┐   │
│  │ Firecracker │      │ NetworkMgr  │      │ SessionMgr   │   │
│  │ Launcher    │      │ (TAP+NAT)   │      │ (Tracking)   │   │
│  └─────────────┘      └─────────────┘      └──────────────┘   │
│         │                    │                                  │
│         ▼                    ▼                                  │
│  ┌─────────────────────────────────┐                          │
│  │ Firecracker VMs (Alpine Linux)  │                          │
│  │ • One process per VM            │                          │
│  │ • TAP networking                │                          │
│  │ • Vsock for guest communication │                          │
│  │ • ~125ms boot time              │                          │
│  └─────────────────────────────────┘                          │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Setup

```bash
# Install Firecracker and setup networking (requires root)
sudo ./scripts/setup.sh
```

### 2. Build templates

Templates are auto-discovered from `$DATA_DIR/templates/<name>/`:
- VM template: directory contains `vmlinux` + `rootfs.ext4`
- Lite template: directory contains a `rootfs/` subdirectory (bwrap root)

```bash
# Ubuntu VM template (full sandbox)
sudo ./scripts/build-ubuntu-rootfs.sh

# cli-lite template (FREE / unlogged tier — bwrap, CLI-only)
sudo ./scripts/build-cli-lite.sh
```

### 3. Run

```bash
cargo run --release
```

## API Usage

### Create Sandbox

```bash
# Authenticated full VM
curl -X POST http://localhost:9000/sandbox \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"template":"ubuntu-base","size":"medium"}'

# Anonymous lite (FREE tier — only allow-listed templates)
curl -X POST http://localhost:9000/sandbox \
  -H "Content-Type: application/json" \
  -d '{"template":"cli-lite"}'
```

Response:
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "ip_address": "10.0.0.2",
  "ws_url": "/sandbox/550e8400-e29b-41d4-a716-446655440000/tty",
  "size": "medium",
  "cost_per_minute": 0.01,
  "state": "running"
}
```

### Execute Command

```bash
curl -X POST http://localhost:9000/sandbox/{id}/exec \
  -H "Content-Type: application/json" \
  -d '{"command": "ls -la"}'
```

### Delete Sandbox

```bash
curl -X DELETE http://localhost:9000/sandbox/{id}
```

### Get Statistics

```bash
curl http://localhost:9000/stats
```

## VM Size Tiers

| Tier | Memory | vCPUs | Cost/min |
|------|--------|-------|----------|
| small | 128MB | 1 | $0.005 |
| medium | 256MB | 1 | $0.01 |
| large | 512MB | 2 | $0.02 |
| xlarge | 1024MB | 4 | $0.04 |

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `BIND_ADDR` | `0.0.0.0:9000` | REST server bind address |
| `NOISE_BIND_ADDR` | `0.0.0.0:9010` | Noise TCP bind address |
| `NOISE_LOCAL_PRIVATE_KEY` | — | 32-byte hex server private key |
| `TEMPLATES_DIR` | `/data/templates` | Template storage |
| `OVERLAYS_DIR` | `/data/overlays` | Runtime files |
| `BRIDGE_NAME` | `br-sandbox` | Network bridge |
| `NETWORK_SUBNET` | `10.0.0.0/16` | VM network |
| `ENABLE_KVM` | `true` | Use KVM (false for mock) |
| `DEFAULT_VM_SIZE` | `medium` | Default size tier |
| `RUST_LOG` | `info` | Log level |

## Noise CLI setup

The CLI talks to `sandbox-manager` over `Noise_NX_25519_ChaChaPoly_BLAKE2b` TCP, not plain HTTP.

Meaning of the env vars:

- `NOISE_LOCAL_PRIVATE_KEY` = server private key
- `NOISE_REMOTE_PUBLIC_KEY` = pinned server public key on the CLI
- `NOISE_ADDR` = client destination address
- `NOISE_BIND_ADDR` = server listen address

Generate a server keypair:

```bash
./scripts/noise-keygen.sh .noise
```

This writes server and client helper env files. With NX, the CLI only needs the server public key.

Start the server:

```bash
set -a
source .noise/server.env
set +a
cargo run --release
```

Run the CLI:

```bash
cd cli && make build/sandbox-linux-x86_64
cd ..
set -a
source .noise/client.env
set +a
./cli/build/sandbox-linux-x86_64 health
```

## Guest Communication (bridge)

VMs run `bridge`, a tiny (~63KB) PTY relay agent that:
1. Connects to `api.todofor.ai/ws/v2/bridge` with an edge token
2. Handles multi-session PTY management per `todoId`
3. Relays terminal I/O between backend and VM shell

### Protocol

```
Backend → bridge:
  {"type":"exec","todoId":"..."}           Spawn PTY
  {"type":"input","todoId":"...","data":"base64"}  Write stdin
  {"type":"resize","todoId":"...","rows":N,"cols":N}
  {"type":"signal","todoId":"...","sig":N}
  {"type":"kill","todoId":"..."}

bridge → Backend:
  {"type":"identity","data":{...}}         Edge info on connect
  {"type":"output","todoId":"...","data":"base64"}  PTY stdout
  {"type":"exit","todoId":"...","code":N}  Session ended
```

### Templates

- **ubuntu-base**: Ubuntu minimal VM with edge agent
- **cli-lite**: bwrap jail with our CLI binaries only — FREE / anonymous tier
- **alpine-edge**: Alpine + bridge, connects to backend on boot

### Booting a sandbox

The caller's API key is the Bearer token. The sandbox-manager:
- derives the owner `user_id` from the token (`resource:token:*` or `apikey:*` in Redis)
- forwards the same token to the VM via kernel cmdline (`enroll.token=...`); bridge inside the VM reads it on boot and enrolls the VM as a device.

```bash
curl -X POST http://localhost:9000/sandbox \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -d '{"template":"alpine-edge"}'
```

## Integration with Resource Proxy

The sandbox-manager is designed to work behind `resource-proxy` for auth and billing:

```
Client → Resource Proxy (auth + billing) → Sandbox Manager
```

Resource proxy handles:
- API key validation
- Balance checking
- Per-minute billing
- WebSocket relay

## Development

```bash
# Run in mock mode (no KVM required)
ENABLE_KVM=false cargo run

# Run with debug logging
RUST_LOG=sandbox_manager=debug cargo run
```

## Future: CoW Fork Engine

The codebase includes a partially-implemented CoW (Copy-on-Write) fork engine (`src/vm/fork.rs`) for sub-millisecond VM creation. This is based on [Zeroboot](https://github.com/zerobootdev/zeroboot).

Benefits when completed:
- ~0.8ms VM creation (vs ~125ms)
- ~265KB memory per VM (only dirty pages)
- Thousands of concurrent VMs

Currently using Firecracker process per VM for simplicity and reliability.
