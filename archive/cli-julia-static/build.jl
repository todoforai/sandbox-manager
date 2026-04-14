#!/usr/bin/env julia
# Build the static sandbox CLI binary

using Pkg
Pkg.activate(@__DIR__; io=devnull)
Pkg.instantiate(; io=devnull)

using StaticCompiler, StaticTools, libsodium_jll

include("src/sandbox_static.jl")

sodium_dir = dirname(libsodium_jll.libsodium)
println("libsodium: $sodium_dir")

# Compile stubs for Julia 1.12 type-check dead code paths
run(`gcc -c $(joinpath(@__DIR__, "jl_stubs.c")) -o $(joinpath(@__DIR__, "build", "jl_stubs.o"))`)

compile_executable(sandbox_main, (Int64, Ptr{Ptr{UInt8}}), joinpath(@__DIR__, "build");
    cflags=`$(joinpath(@__DIR__, "build", "jl_stubs.o")) -L$sodium_dir -lsodium -Wl,-rpath,$sodium_dir`)

build_path = joinpath(@__DIR__, "build", "sandbox_main")
println("Built: $build_path")
run(`ls -lh $build_path`)
run(`ldd $build_path`)
