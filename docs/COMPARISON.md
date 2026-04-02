# Sandbox Technology Comparison

Comprehensive comparison of VM/sandbox technologies for AI agent execution.

## Executive Summary

| Technology | Spawn Time | Memory/VM | Isolation | Best For |
|------------|------------|-----------|-----------|----------|
| **Zeroboot** | **0.79ms** | **265KB** | Hardware (KVM) | Highest density, batch execution |
| Firecracker | 125ms | ~5MB overhead | Hardware (KVM) | AWS Lambda, serverless |
| E2B | ~150ms | ~128MB | Hardware (KVM) | Production AI agents |
| Fly Machines | 1-12s | Variable | Hardware (KVM) | Persistent workloads |
| gVisor | ~50ms | ~30MB | Syscall intercept | GPU workloads |
| Docker | ~500ms | Shared kernel | Namespace | Development, trusted code |

**Zeroboot is 156x faster than Firecracker and 190x faster than E2B** for spawn time.

---

## Detailed Comparison

### 1. Spawn Latency

```
Zeroboot      ████ 0.79ms (CoW fork)
BoxLite       ████████████████████ <50ms
gVisor        ██████████████████████████ ~50ms
Daytona       ████████████████████████████████████ 90ms
Firecracker   ██████████████████████████████████████████████████ 125ms
E2B           ████████████████████████████████████████████████████████████ ~150ms
Kata          ████████████████████████████████████████████████████████████████████████████ 150-300ms
Fly Machines  ████████████████████████████████████████████████████████████████████████████████████████████████████ 1-12s
```

| Technology | Cold Start | Snapshot Restore | CoW Fork |
|------------|------------|------------------|----------|
| **Zeroboot** | N/A | N/A | **0.79ms** |
| Firecracker | 125ms | 5-10ms | N/A |
| BoxLite | <50ms | — | — |
| E2B | ~150ms | — | — |
| Daytona | 90ms | — | — |
| gVisor | ~50ms | — | — |
| Kata Containers | 150-300ms | — | — |
| Fly Machines | 1-12s | ~300ms | — |

### 2. Memory Efficiency

| Technology | Overhead/VM | With CoW | 1000 VMs |
|------------|-------------|----------|----------|
| **Zeroboot** | ~5MB | **265KB** | **~265MB** |
| Firecracker | ~5MB | N/A | ~5GB |
| E2B | ~128MB | N/A | ~128GB |
| gVisor | ~30MB | N/A | ~30GB |
| Kata | ~130MB | N/A | ~130GB |

**Zeroboot achieves ~480x better memory density than E2B** through copy-on-write.

### 3. Isolation Level

| Technology | Method | Escape Difficulty | Suitable For |
|------------|--------|-------------------|--------------|
| **Zeroboot** | KVM hardware | Nation-state | Untrusted code |
| Firecracker | KVM hardware | Nation-state | Untrusted code |
| E2B | Firecracker (KVM) | Nation-state | Untrusted code |
| Cloud Hypervisor | KVM hardware | Nation-state | Untrusted code |
| Kata Containers | KVM hardware | Nation-state | Untrusted code |
| gVisor | Syscall intercept | Kernel exploit | Semi-trusted |
| Docker | Namespaces | Container escape | Trusted code |

### 4. Feature Matrix

| Feature | Zeroboot | Firecracker | E2B | Fly | gVisor | Kata |
|---------|----------|-------------|-----|-----|--------|------|
| Sub-ms spawn | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| CoW memory | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Networking | ⚠️ WIP | ✅ | ✅ | ✅ | ✅ | ✅ |
| Multi-vCPU | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| GPU support | ❌ | ❌ | ❌ | ✅ | ✅ | ⚠️ |
| Kubernetes | ❌ | ⚠️ | ❌ | ✅ | ✅ | ✅ |
| Hibernation | ❌ | ✅ | ❌ | ✅ | ❌ | ❌ |
| Open source | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Managed service | ⚠️ | ❌ | ✅ | ✅ | ❌ | ❌ |

### 5. Pricing Comparison (Managed Services)

| Platform | Cost/CPU/Second | Monthly Min | Notes |
|----------|-----------------|-------------|-------|
| **Fly.io** | $0.00000053 | ~$0 | Cheapest, slower spawn |
| Modal | $0.0000131 | $30 credits | GPU support |
| E2B | $0.000028 | — | Open-source option |
| Together | $0.0000248 | — | VM-style |
| **Self-hosted Zeroboot** | ~$0.0000001* | Server cost | *Estimated at scale |

*Self-hosted Zeroboot on a €200/month server with 100K VMs/day ≈ $0.0000001/CPU/second

---

## Technology Deep Dives

### Zeroboot (Copy-on-Write Fork)

**How it works:**
```
1. Boot Firecracker VM once → snapshot memory + CPU state
2. Fork: mmap(MAP_PRIVATE) snapshot → CoW semantics
3. Each fork shares base memory, only writes create copies
4. Result: 0.79ms spawn, 265KB per VM
```

**Advantages:**
- 156x faster than Firecracker cold boot
- 480x better memory density than E2B
- Same KVM isolation as Firecracker

**Limitations:**
- No networking (yet) — must add TAP post-fork
- Single vCPU only
- Shared CSPRNG state (must reseed)
- ~15s template update time

**Best for:** High-throughput batch execution, agent evaluations, cost-sensitive deployments

### Firecracker (AWS)

**How it works:**
```
Minimal VMM (83K lines Rust) → KVM → microVM
- No BIOS, no PCI, no USB
- Only virtio-net, virtio-block, serial
- Snapshot/restore for fast resume
```

**Advantages:**
- Battle-tested (AWS Lambda scale)
- Minimal attack surface
- Snapshot restore in 5-10ms

**Limitations:**
- 125ms cold boot
- No GPU passthrough
- No nested virtualization

**Best for:** Serverless functions, multi-tenant isolation

### E2B (Managed Firecracker)

**How it works:**
```
Firecracker + managed infrastructure + SDK
- Pre-built templates (Python, Node, etc.)
- Filesystem API for file operations
- WebSocket for streaming
```

**Advantages:**
- Production-ready (200M+ sandboxes)
- Great SDK/DX
- Open-source runtime option

**Limitations:**
- ~150ms spawn time
- ~128MB per sandbox
- Managed service cost

**Best for:** AI agent platforms, code execution APIs

### gVisor (Google)

**How it works:**
```
User-space kernel (Sentry) intercepts syscalls
- No VM, no hypervisor
- Implements ~274 Linux syscalls
- Runs as OCI runtime (runsc)
```

**Advantages:**
- ~50ms startup
- GPU support
- Lower overhead than VMs

**Limitations:**
- Weaker isolation (no hardware boundary)
- Incomplete syscall coverage
- 10-30% I/O overhead

**Best for:** GPU workloads, semi-trusted code

### Kata Containers

**How it works:**
```
OCI runtime → VM per container
- Supports multiple VMMs (Firecracker, Cloud Hypervisor)
- Kubernetes-native (kata-runtime)
- Full guest kernel per container
```

**Advantages:**
- Kubernetes integration
- Enterprise support
- Flexible VMM choice

**Limitations:**
- 150-300ms startup
- ~130MB overhead
- Operational complexity

**Best for:** Enterprise Kubernetes, regulated workloads

---

## Decision Matrix

### Choose Zeroboot if:
- ✅ You need sub-millisecond spawn time
- ✅ You're running thousands of short-lived VMs
- ✅ Memory efficiency is critical
- ✅ You can add networking post-fork
- ✅ Single vCPU is sufficient

### Choose Firecracker if:
- ✅ You need proven production stability
- ✅ You want snapshot/restore (5-10ms)
- ✅ You need multi-vCPU support
- ✅ You're building Lambda-like infrastructure

### Choose E2B if:
- ✅ You want managed infrastructure
- ✅ You need great SDK/developer experience
- ✅ 150ms spawn time is acceptable
- ✅ You prefer not to manage VMs

### Choose gVisor if:
- ✅ You need GPU support
- ✅ VM overhead is unacceptable
- ✅ Code is semi-trusted
- ✅ You're on Kubernetes

### Choose Kata Containers if:
- ✅ You need Kubernetes-native solution
- ✅ Enterprise support is required
- ✅ You have regulated workloads
- ✅ Startup time is less critical

---

## Benchmark Summary

### Spawn Time (Lower is Better)
```
Zeroboot:     0.79ms  ████
Firecracker:  125ms   ████████████████████████████████████████████████████████████████
E2B:          150ms   ████████████████████████████████████████████████████████████████████████████
```

### Memory per 1000 VMs (Lower is Better)
```
Zeroboot:     265MB   ████
Firecracker:  5GB     ████████████████████
E2B:          128GB   ████████████████████████████████████████████████████████████████████████████████████████████████████
```

### VMs per 256GB Server (Higher is Better)
```
Zeroboot:     ~100,000  ████████████████████████████████████████████████████████████████████████████████████████████████████
Firecracker:  ~50,000   ██████████████████████████████████████████████████
E2B:          ~2,000    ██
```

---

## Conclusion

**Zeroboot represents a 100-1000x improvement** in spawn time and memory efficiency over existing solutions, while maintaining the same hardware-level isolation.

| Metric | Zeroboot vs Firecracker | Zeroboot vs E2B |
|--------|-------------------------|-----------------|
| Spawn time | **156x faster** | **190x faster** |
| Memory/VM | **~20x better** | **~480x better** |
| Isolation | Same (KVM) | Same (KVM) |

**Trade-off:** Zeroboot currently lacks networking and multi-vCPU, making it best suited for batch workloads. For production AI agents requiring full networking, use Firecracker with snapshot restore (~5-10ms) until Zeroboot adds networking support.

---

## References

- [Zeroboot GitHub](https://github.com/zerobootdev/zeroboot)
- [Firecracker GitHub](https://github.com/firecracker-microvm/firecracker)
- [E2B Documentation](https://e2b.dev/docs)
- [gVisor Documentation](https://gvisor.dev/)
- [Kata Containers](https://katacontainers.io/)
- [Modal Blog: Top Code Agent Sandbox Products](https://modal.com/blog/top-code-agent-sandbox-products)
