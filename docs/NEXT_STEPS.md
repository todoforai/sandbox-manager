# Sandbox Integration - Next Steps

## Current State

### ✅ Working
- **bridge**: Full PTY relay agent (64KB), connects to `wss://api.todofor.ai/ws/v2/bridge`
- **BridgeHandler**: Backend WebSocket handler for bridge (edge) connections
- **NetworkManager**: TAP device creation, bridge setup, NAT, VM isolation
- **Firecracker launcher**: VM boot with edge token injection via kernel cmdline

### ⚠️ Needs Work
1. Real backend connection testing with valid edge token
2. Auth/billing integration (directly in backend)
3. TAP networking (requires root)

---

## 1. Test Real Backend Connection

### What's Needed
The VM boots with the enroll token injected via Firecracker MMDS (169.254.169.254). The guest `/init` fetches it, runs `todoforai-bridge login --token`, and bridge connects to backend.

### Test Flow
```bash
# 1. Get a valid edge token (from backend)
# Option A: Use existing API key
TOKEN="your-api-key"

# Option B: Generate resource token via tRPC
# POST /trpc/resource.getToken → short-lived token stored in Redis as resource:token:xxx

# 2. Boot sandbox (user derived from Bearer token; enroll token is the same bearer,
#    injected into the VM's kernel cmdline automatically)
curl -X POST http://localhost:9000/sandbox \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"template":"ubuntu-base"}'

# 3. Check backend logs for edge connection
# Should see: [Bridge] Connected: edge=... user=...
```

### Token Generation
Backend needs endpoint to issue sandbox tokens. Add to `backend/src/api/trpc/resource.ts`:

```typescript
// Issue token for sandbox VM
sandboxToken: protectedProcedure
  .input(z.object({ sandboxId: z.string() }))
  .mutation(async ({ ctx, input }) => {
    const token = crypto.randomUUID();
    await redis.set(`resource:token:${token}`, ctx.userId, 'EX', 3600); // 1hr
    return { token };
  }),
```

---

## 2. Auth & Billing Integration

Sandbox-manager should authenticate requests directly via backend (API key / resource token)
and meter usage against user balance. No separate gateway service.

---

## 3. TAP Networking (Requires Root)

### Current Implementation
`sandbox-manager/src/vm/network.rs` has full TAP setup:
- Bridge creation (`br-sandbox`)
- TAP device per VM
- NAT via iptables MASQUERADE
- Inter-VM isolation

### Why Root is Needed
```bash
ip tuntap add tap-xxx mode tap    # Requires CAP_NET_ADMIN
ip link set tap-xxx master br-sandbox
iptables -t nat -A POSTROUTING ...  # Requires CAP_NET_ADMIN
```

### Options

#### A. Run as Root (Development)
```bash
sudo ./target/release/sandbox-manager
```

#### B. Capabilities (Production)
```bash
# Grant network capabilities to binary
sudo setcap cap_net_admin+ep ./target/release/sandbox-manager

# Or run in container with:
docker run --cap-add=NET_ADMIN ...
```

#### C. Network Namespace (Isolated)
```bash
# Create namespace with pre-configured bridge
ip netns add sandbox-ns
ip netns exec sandbox-ns ip link add br-sandbox type bridge
# ... then run sandbox-manager inside namespace
```

### Verify Networking Works
```bash
# Inside VM (via serial console or bridge exec)
ip addr show eth0          # Should have 10.0.0.x
ping -c1 10.0.0.1          # Gateway (host bridge)
ping -c1 8.8.8.8           # Internet (if NAT works)
curl https://api.todofor.ai/health  # Full connectivity
```

---

## Quick Start Checklist

### Prerequisites
- [ ] Firecracker binary installed
- [ ] Linux kernel (`vmlinux`) for VMs
- [ ] Root filesystem with bridge (`rootfs-bridge.ext4`)
- [ ] Backend running with Redis

### Build
```bash
# Build sandbox-manager
cd sandbox-manager && cargo build --release

# Build bridge (if not already in rootfs) — static musl, ~90 KB
cd bridge && make static

# Build rootfs with bridge
sudo ./scripts/build-ubuntu-rootfs.sh
```

### Run
```bash
# Terminal 1: Backend
cd backend && bun run dev

# Terminal 2: Sandbox Manager (as root for networking)
sudo RUST_LOG=debug ./target/release/sandbox-manager

# Terminal 3: Test
curl -X POST http://localhost:9000/sandbox \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"template":"ubuntu-base"}'
```

---

## File References

| Component | File |
|-----------|------|
| bridge main | `bridge/main.c` |
| Edge token injection | `sandbox-manager/src/vm/firecracker.rs:243` |
| TAP networking | `sandbox-manager/src/vm/network.rs` |
| BridgeHandler | `backend/src/api/ws/handlers/BridgeHandler.ts` |
| Init script (VM) | `sandbox-manager/scripts/build-ubuntu-rootfs.sh:68` |
