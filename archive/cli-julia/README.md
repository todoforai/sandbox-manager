# sandbox CLI (Julia)

Julia port of the sandbox-manager CLI. Communicates with `sandbox-manager` over **Noise_IK_25519_ChaChaPoly_BLAKE2s** TCP.

Functionally equivalent to the [Zig CLI](../cli/), with the same commands, env vars, and wire protocol.

## Architecture

```
SandboxCLI.jl          CLI entry point, arg parsing, JSON display
  └─ noise.jl          Noise_IK handshake + transport state machine
       └─ crypto.jl    X25519, ChaCha20-Poly1305 (libsodium), HMAC/HKDF
            └─ blake2s.jl  Pure Julia BLAKE2s-256 (RFC 7693)
```

Crypto: `libsodium_jll` for X25519 DH and ChaCha20-Poly1305 AEAD. BLAKE2s is pure Julia (~120 lines) since libsodium only ships BLAKE2b.

## Usage

```bash
# Run directly
julia --project=. sandbox.jl health

# Or from repo root
julia --project=sandbox-manager/cli-jl sandbox-manager/cli-jl/sandbox.jl health
```

## Commands

```
sandbox health                          Health check
sandbox stats                           VM statistics
sandbox create --user <id> [opts]       Create sandbox VM
  --template <name>                     Template (default: alpine-base)
  --size <small|medium|large|xlarge>
  --token <api-key>                     Auth token
sandbox list [--user <id>]              List sandboxes
sandbox get <id>                        Get sandbox details
sandbox delete <id>                     Delete sandbox
sandbox pause <id>                      Pause sandbox
sandbox resume <id>                     Resume sandbox
sandbox template list                   List templates
sandbox template create <name> --kernel <path> --rootfs <path>
```

## Environment

| Variable | Description | Default |
|---|---|---|
| `NOISE_ADDR` | sandbox-manager Noise address | `127.0.0.1:9001` |
| `NOISE_LOCAL_PRIVATE_KEY` | 32-byte hex CLI private key | required |
| `NOISE_REMOTE_PUBLIC_KEY` | 32-byte hex server public key | required |

`NOISE_LOCAL_PRIVATE_KEY` is always this CLI process's private key.
`NOISE_REMOTE_PUBLIC_KEY` is always the `sandbox-manager` server public key.

Generate matching client/server env files from the repo root:

```bash
./sandbox-manager/scripts/noise-keygen.sh sandbox-manager/.noise
```

Then load the client env before running the CLI:

```bash
set -a
source sandbox-manager/.noise/client.env
set +a
julia --project=sandbox-manager/cli-jl sandbox-manager/cli-jl/sandbox.jl health
```

## Tests

```bash
julia --project=. test.jl
```

Runs BLAKE2s test vectors, crypto primitive tests, and a full Noise_IK handshake self-test (initiator + manual responder).

## Why not StaticCompiler.jl?

StaticCompiler.jl only supports a tiny subset of Julia (no heap, no networking, no JSON). The Noise protocol needs TCP sockets, dynamic allocation, and JSON serialization — none of which are compatible with static compilation.

This implementation uses standard Julia with `libsodium_jll` (bundled via Julia's artifact system). For a standalone binary, use [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl):

```julia
using PackageCompiler
create_app(".", "build"; executables=["sandbox" => "SandboxCLI.main"])
```
