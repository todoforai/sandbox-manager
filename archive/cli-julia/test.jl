#!/usr/bin/env julia
# Comprehensive test suite for the Julia Noise_IK implementation.
# Tests: BLAKE2s vectors, HMAC/HKDF, crypto primitives, full handshake.

using Pkg
Pkg.activate(@__DIR__; io=devnull)

include("src/noise.jl")
using .NoiseProtocol
using .NoiseProtocol.NoiseCrypto
using .NoiseProtocol.NoiseCrypto.Blake2s

passed = 0
failed = 0

macro check(desc, expr)
    quote
        try
            @assert $(esc(expr))
            println("  ✓ ", $(esc(desc)))
            global passed += 1
        catch e
            printstyled("  ✗ ", $(esc(desc)), "\n"; color=:red)
            global failed += 1
        end
    end
end

# ── BLAKE2s test vectors ───────────────────────────────────────────────────────

println("=== BLAKE2s ===")

# RFC 7693 Appendix A
@check "BLAKE2s(\"abc\") matches RFC 7693" begin
    bytes2hex(Blake2s.hash(Vector{UInt8}(b"abc"))) ==
    "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982"
end

# Empty input
@check "BLAKE2s(\"\") known value" begin
    bytes2hex(Blake2s.hash(UInt8[])) ==
    "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"
end

# Exact block boundary (64 bytes)
@check "BLAKE2s(64 zero bytes)" begin
    h = Blake2s.hash(zeros(UInt8, 64))
    length(h) == 32
end

# Multi-block (65 bytes)
@check "BLAKE2s(65 zero bytes)" begin
    h = Blake2s.hash(zeros(UInt8, 65))
    length(h) == 32
end

# Long input (1000 bytes)
@check "BLAKE2s(1000 bytes)" begin
    h = Blake2s.hash(collect(UInt8, 0x00:0xff) |> x -> repeat(x, 4)[1:1000])
    length(h) == 32
end

# Incremental vs one-shot
@check "BLAKE2s incremental == one-shot" begin
    data = Vector{UInt8}(b"hello world, this is a test of incremental hashing")
    one_shot = Blake2s.hash(data)
    s = Blake2s.State()
    Blake2s.update!(s, data[1:10])
    Blake2s.update!(s, data[11:end])
    incremental = Blake2s.final!(s)
    one_shot == incremental
end

# Incremental with exact block boundary split
@check "BLAKE2s incremental at block boundary" begin
    data = rand(UInt8, 128)
    one_shot = Blake2s.hash(data)
    s = Blake2s.State()
    Blake2s.update!(s, data[1:64])
    Blake2s.update!(s, data[65:128])
    incremental = Blake2s.final!(s)
    one_shot == incremental
end

# ── Crypto primitives ──────────────────────────────────────────────────────────

println("\n=== Crypto primitives ===")

@check "X25519 DH commutativity" begin
    a = NoiseCrypto.generate_keypair()
    b = NoiseCrypto.generate_keypair()
    NoiseCrypto.dh(a.secret, b.public) == NoiseCrypto.dh(b.secret, a.public)
end

@check "X25519 keypair_from_secret recovers public" begin
    kp = NoiseCrypto.generate_keypair()
    kp2 = NoiseCrypto.keypair_from_secret(kp.secret)
    kp.public == kp2.public
end

@check "AEAD encrypt/decrypt roundtrip" begin
    key = rand(UInt8, 32)
    nonce = NoiseCrypto.nonce_bytes(UInt64(0))
    ad = Vector{UInt8}(b"ad")
    pt = Vector{UInt8}(b"hello")
    ct = NoiseCrypto.aead_encrypt(key, nonce, ad, pt)
    length(ct) == length(pt) + 16 &&
    NoiseCrypto.aead_decrypt(key, nonce, ad, ct) == pt
end

@check "AEAD rejects wrong key" begin
    key = rand(UInt8, 32)
    nonce = NoiseCrypto.nonce_bytes(UInt64(0))
    ct = NoiseCrypto.aead_encrypt(key, nonce, UInt8[], Vector{UInt8}(b"x"))
    try
        NoiseCrypto.aead_decrypt(rand(UInt8, 32), nonce, UInt8[], ct)
        false
    catch
        true
    end
end

@check "AEAD rejects wrong AD" begin
    key = rand(UInt8, 32)
    nonce = NoiseCrypto.nonce_bytes(UInt64(0))
    ct = NoiseCrypto.aead_encrypt(key, nonce, Vector{UInt8}(b"ad1"), Vector{UInt8}(b"x"))
    try
        NoiseCrypto.aead_decrypt(key, nonce, Vector{UInt8}(b"ad2"), ct)
        false
    catch
        true
    end
end

@check "AEAD empty plaintext" begin
    key = rand(UInt8, 32)
    nonce = NoiseCrypto.nonce_bytes(UInt64(0))
    ct = NoiseCrypto.aead_encrypt(key, nonce, UInt8[], UInt8[])
    length(ct) == 16 &&
    NoiseCrypto.aead_decrypt(key, nonce, UInt8[], ct) == UInt8[]
end

@check "Nonce encoding: 4 zero bytes + 8-byte LE counter" begin
    n = NoiseCrypto.nonce_bytes(UInt64(1))
    n[1:4] == zeros(UInt8, 4) && n[5] == 0x01 && all(==(0), n[6:12])
end

# ── HMAC / HKDF ───────────────────────────────────────────────────────────────

println("\n=== HMAC / HKDF ===")

@check "HMAC deterministic" begin
    k = Vector{UInt8}(b"key")
    d = Vector{UInt8}(b"data")
    NoiseCrypto.hmac_blake2s(k, d) == NoiseCrypto.hmac_blake2s(k, d)
end

@check "HMAC different keys → different output" begin
    d = Vector{UInt8}(b"data")
    NoiseCrypto.hmac_blake2s(Vector{UInt8}(b"key1"), d) !=
    NoiseCrypto.hmac_blake2s(Vector{UInt8}(b"key2"), d)
end

@check "HMAC different data → different output" begin
    k = Vector{UInt8}(b"key")
    NoiseCrypto.hmac_blake2s(k, Vector{UInt8}(b"data1")) !=
    NoiseCrypto.hmac_blake2s(k, Vector{UInt8}(b"data2"))
end

@check "HKDF2 returns two distinct 32-byte outputs" begin
    o1, o2 = NoiseCrypto.hkdf2(zeros(UInt8, 32), UInt8[])
    length(o1) == 32 && length(o2) == 32 && o1 != o2
end

@check "HKDF3 returns three distinct 32-byte outputs" begin
    o1, o2, o3 = NoiseCrypto.hkdf3(zeros(UInt8, 32), UInt8[])
    length(o1) == 32 && length(o2) == 32 && length(o3) == 32 &&
    o1 != o2 && o2 != o3 && o1 != o3
end

@check "HKDF2 deterministic" begin
    ck = rand(UInt8, 32)
    ikm = Vector{UInt8}(b"input")
    NoiseCrypto.hkdf2(ck, ikm) == NoiseCrypto.hkdf2(ck, ikm)
end

# ── Noise IK handshake ─────────────────────────────────────────────────────────

println("\n=== Noise IK handshake ===")

@check "Full IK handshake self-test" begin
    init_static = NoiseCrypto.generate_keypair()
    resp_static = NoiseCrypto.generate_keypair()

    # Initiator
    init_hs = NoiseProtocol.HandshakeState(init_static, resp_static.public)

    # Responder (manual)
    resp_ss = NoiseProtocol.SymmetricState(collect(UInt8, NoiseProtocol.PROTOCOL_NAME))
    NoiseProtocol.mix_hash!(resp_ss, resp_static.public)

    # msg1
    msg1 = NoiseProtocol.write_message1!(init_hs)

    off = 1
    re = msg1[off:off+31]; NoiseProtocol.mix_hash!(resp_ss, re); off += 32
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_static.secret, re))
    extra = NoiseProtocol.has_key(resp_ss.cipher) ? 16 : 0
    init_pub = NoiseProtocol.decrypt_and_hash!(resp_ss, msg1[off:off+31+extra]); off += 32 + extra
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_static.secret, init_pub))
    NoiseProtocol.decrypt_and_hash!(resp_ss, msg1[off:end])

    # msg2
    resp_e = NoiseCrypto.generate_keypair()
    msg2 = copy(resp_e.public)
    NoiseProtocol.mix_hash!(resp_ss, resp_e.public)
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_e.secret, re))
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_e.secret, init_pub))
    append!(msg2, NoiseProtocol.encrypt_and_hash!(resp_ss, UInt8[]))

    NoiseProtocol.read_message2!(init_hs, msg2)

    # Verify
    init_hs.complete &&
    init_hs.symmetric.h == resp_ss.h
end

@check "Transport roundtrip after handshake" begin
    init_static = NoiseCrypto.generate_keypair()
    resp_static = NoiseCrypto.generate_keypair()

    init_hs = NoiseProtocol.HandshakeState(init_static, resp_static.public)
    resp_ss = NoiseProtocol.SymmetricState(collect(UInt8, NoiseProtocol.PROTOCOL_NAME))
    NoiseProtocol.mix_hash!(resp_ss, resp_static.public)

    msg1 = NoiseProtocol.write_message1!(init_hs)
    off = 1
    re = msg1[off:off+31]; NoiseProtocol.mix_hash!(resp_ss, re); off += 32
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_static.secret, re))
    extra = NoiseProtocol.has_key(resp_ss.cipher) ? 16 : 0
    init_pub = NoiseProtocol.decrypt_and_hash!(resp_ss, msg1[off:off+31+extra]); off += 32 + extra
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_static.secret, init_pub))
    NoiseProtocol.decrypt_and_hash!(resp_ss, msg1[off:end])

    resp_e = NoiseCrypto.generate_keypair()
    msg2 = copy(resp_e.public)
    NoiseProtocol.mix_hash!(resp_ss, resp_e.public)
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_e.secret, re))
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_e.secret, init_pub))
    append!(msg2, NoiseProtocol.encrypt_and_hash!(resp_ss, UInt8[]))

    NoiseProtocol.read_message2!(init_hs, msg2)

    init_t = NoiseProtocol.to_transport(init_hs)
    i_cs, r_cs = NoiseProtocol.split(resp_ss)
    resp_t = NoiseProtocol.TransportState(r_cs, i_cs)

    # i→r
    msg = Vector{UInt8}(b"hello from initiator")
    ct = NoiseProtocol.write_transport!(init_t, msg)
    pt = NoiseProtocol.read_transport!(resp_t, ct)
    pt == msg || error("i→r failed")

    # r→i
    msg2_t = Vector{UInt8}(b"hello from responder")
    ct2 = NoiseProtocol.write_transport!(resp_t, msg2_t)
    pt2 = NoiseProtocol.read_transport!(init_t, ct2)
    pt2 == msg2_t
end

@check "Multiple transport messages" begin
    init_static = NoiseCrypto.generate_keypair()
    resp_static = NoiseCrypto.generate_keypair()

    init_hs = NoiseProtocol.HandshakeState(init_static, resp_static.public)
    resp_ss = NoiseProtocol.SymmetricState(collect(UInt8, NoiseProtocol.PROTOCOL_NAME))
    NoiseProtocol.mix_hash!(resp_ss, resp_static.public)

    msg1 = NoiseProtocol.write_message1!(init_hs)
    off = 1
    re = msg1[off:off+31]; NoiseProtocol.mix_hash!(resp_ss, re); off += 32
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_static.secret, re))
    extra = NoiseProtocol.has_key(resp_ss.cipher) ? 16 : 0
    init_pub = NoiseProtocol.decrypt_and_hash!(resp_ss, msg1[off:off+31+extra]); off += 32 + extra
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_static.secret, init_pub))
    NoiseProtocol.decrypt_and_hash!(resp_ss, msg1[off:end])

    resp_e = NoiseCrypto.generate_keypair()
    msg2 = copy(resp_e.public)
    NoiseProtocol.mix_hash!(resp_ss, resp_e.public)
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_e.secret, re))
    NoiseProtocol.mix_key!(resp_ss, NoiseCrypto.dh(resp_e.secret, init_pub))
    append!(msg2, NoiseProtocol.encrypt_and_hash!(resp_ss, UInt8[]))

    NoiseProtocol.read_message2!(init_hs, msg2)

    init_t = NoiseProtocol.to_transport(init_hs)
    i_cs, r_cs = NoiseProtocol.split(resp_ss)
    resp_t = NoiseProtocol.TransportState(r_cs, i_cs)

    ok = true
    for i in 1:10
        msg = Vector{UInt8}("message $i" |> collect .|> UInt8)
        ct = NoiseProtocol.write_transport!(init_t, msg)
        pt = NoiseProtocol.read_transport!(resp_t, ct)
        ok &= (pt == msg)
    end
    ok
end

# ── Summary ────────────────────────────────────────────────────────────────────

println("\n" * "="^50)
total = passed + failed
if failed == 0
    printstyled("All $total tests passed!\n"; color=:green)
else
    printstyled("$passed/$total passed, $failed failed\n"; color=:red)
    exit(1)
end
