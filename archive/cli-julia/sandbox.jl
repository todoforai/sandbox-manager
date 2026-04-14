#!/usr/bin/env julia
# sandbox CLI — manages Firecracker VMs via Noise_IK TCP to sandbox-manager
#
# Config (env):
#   NOISE_ADDR              host:port of sandbox-manager Noise server (default: 127.0.0.1:9001)
#   NOISE_LOCAL_PRIVATE_KEY 32-byte hex — CLI private key
#   NOISE_REMOTE_PUBLIC_KEY 32-byte hex — sandbox-manager public key
#
# Usage:
#   julia sandbox.jl health
#   julia sandbox.jl create --user <id> [--template alpine-base] [--size medium]

using Pkg
Pkg.activate(@__DIR__; io=devnull)

include("src/SandboxCLI.jl")
SandboxCLI.main()
