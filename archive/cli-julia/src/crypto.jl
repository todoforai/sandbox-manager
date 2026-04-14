# Crypto primitives for Noise_IK_25519_ChaChaPoly_BLAKE2s
# Uses libsodium for X25519 and ChaCha20-Poly1305, pure Julia for BLAKE2s

module NoiseCrypto

using libsodium_jll
include("blake2s.jl")

const DH_LEN = 32
const KEY_LEN = 32
const HASH_LEN = 32
const NONCE_LEN = 12
const TAG_LEN = 16

struct KeyPair
    secret::Vector{UInt8}  # 32 bytes
    public::Vector{UInt8}  # 32 bytes
end

# ── X25519 ─────────────────────────────────────────────────────────────────────

function generate_keypair()::KeyPair
    secret = Vector{UInt8}(undef, 32)
    public = Vector{UInt8}(undef, 32)
    ccall((:randombytes_buf, libsodium), Cvoid, (Ptr{UInt8}, Csize_t), secret, 32)
    ret = ccall((:crypto_scalarmult_curve25519_base, libsodium), Cint, (Ptr{UInt8}, Ptr{UInt8}), public, secret)
    ret == 0 || error("crypto_scalarmult_curve25519_base failed")
    KeyPair(secret, public)
end

function keypair_from_secret(secret::Vector{UInt8})::KeyPair
    length(secret) == 32 || error("secret key must be 32 bytes")
    public = Vector{UInt8}(undef, 32)
    ret = ccall((:crypto_scalarmult_curve25519_base, libsodium), Cint, (Ptr{UInt8}, Ptr{UInt8}), public, secret)
    ret == 0 || error("crypto_scalarmult_curve25519_base failed")
    KeyPair(copy(secret), public)
end

function dh(secret::Vector{UInt8}, public::Vector{UInt8})::Vector{UInt8}
    out = Vector{UInt8}(undef, 32)
    ret = ccall((:crypto_scalarmult_curve25519, libsodium), Cint,
                (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}), out, secret, public)
    ret == 0 || error("X25519 DH failed")
    out
end

# ── BLAKE2s hash / HMAC / HKDF ────────────────────────────────────────────────

hash(data::AbstractVector{UInt8}) = Blake2s.hash(data)

function hmac_blake2s(key::AbstractVector{UInt8}, data::AbstractVector{UInt8})::Vector{UInt8}
    # HMAC(K, m) = H((K' ⊕ opad) || H((K' ⊕ ipad) || m))
    block_size = Blake2s.BLOCK_SIZE
    k = if length(key) > block_size
        Blake2s.hash(collect(UInt8, key))
    else
        collect(UInt8, key)
    end
    # Pad key to block_size
    padded = zeros(UInt8, block_size)
    copyto!(padded, 1, k, 1, length(k))

    ipad = padded .⊻ 0x36
    opad = padded .⊻ 0x5c

    # Inner hash
    inner = Blake2s.State()
    Blake2s.update!(inner, ipad)
    Blake2s.update!(inner, collect(UInt8, data))
    inner_hash = Blake2s.final!(inner)

    # Outer hash
    outer = Blake2s.State()
    Blake2s.update!(outer, opad)
    Blake2s.update!(outer, inner_hash)
    Blake2s.final!(outer)
end

function hkdf2(chaining_key::Vector{UInt8}, input_key_material::AbstractVector{UInt8})
    # HKDF with 2 outputs (Noise spec §4.3)
    prk = hmac_blake2s(chaining_key, input_key_material)
    out1 = hmac_blake2s(prk, UInt8[0x01])
    out2 = hmac_blake2s(prk, vcat(out1, UInt8[0x02]))
    (out1, out2)
end

function hkdf3(chaining_key::Vector{UInt8}, input_key_material::AbstractVector{UInt8})
    prk = hmac_blake2s(chaining_key, input_key_material)
    out1 = hmac_blake2s(prk, UInt8[0x01])
    out2 = hmac_blake2s(prk, vcat(out1, UInt8[0x02]))
    out3 = hmac_blake2s(prk, vcat(out2, UInt8[0x03]))
    (out1, out2, out3)
end

# ── ChaCha20-Poly1305 AEAD ────────────────────────────────────────────────────

function aead_encrypt(key::Vector{UInt8}, nonce::Vector{UInt8}, ad::Vector{UInt8}, plaintext::Vector{UInt8})
    ciphertext = Vector{UInt8}(undef, length(plaintext))
    tag = Vector{UInt8}(undef, TAG_LEN)
    maclen = Ref{Culonglong}(0)
    ret = ccall((:crypto_aead_chacha20poly1305_ietf_encrypt_detached, libsodium), Cint,
                (Ptr{UInt8}, Ptr{UInt8}, Ptr{Culonglong}, Ptr{UInt8}, Culonglong,
                 Ptr{UInt8}, Culonglong, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}),
                ciphertext, tag, maclen, plaintext, length(plaintext),
                ad, length(ad), C_NULL, nonce, key)
    ret == 0 || error("AEAD encrypt failed")
    vcat(ciphertext, tag)
end

function aead_decrypt(key::Vector{UInt8}, nonce::Vector{UInt8}, ad::Vector{UInt8}, ciphertext_with_tag::Vector{UInt8})
    length(ciphertext_with_tag) >= TAG_LEN || error("ciphertext too short")
    msg_len = length(ciphertext_with_tag) - TAG_LEN
    ct = @view ciphertext_with_tag[1:msg_len]
    tag = @view ciphertext_with_tag[msg_len+1:end]
    plaintext = Vector{UInt8}(undef, msg_len)
    ret = ccall((:crypto_aead_chacha20poly1305_ietf_decrypt_detached, libsodium), Cint,
                (Ptr{UInt8}, Ptr{Cvoid}, Ptr{UInt8}, Culonglong,
                 Ptr{UInt8}, Ptr{UInt8}, Culonglong, Ptr{UInt8}, Ptr{UInt8}),
                plaintext, C_NULL, ct, msg_len,
                tag, ad, length(ad), nonce, key)
    ret == 0 || error("AEAD decrypt failed (authentication)")
    plaintext
end

function nonce_bytes(n::UInt64)::Vector{UInt8}
    # 12-byte nonce: 4 zero bytes + 8-byte little-endian counter
    buf = zeros(UInt8, NONCE_LEN)
    for i in 0:7
        buf[5 + i] = UInt8((n >> (8 * i)) & 0xff)
    end
    buf
end

# ── Init libsodium ─────────────────────────────────────────────────────────────

function __init__()
    ret = ccall((:sodium_init, libsodium), Cint, ())
    ret >= 0 || error("sodium_init failed")
end

end # module
