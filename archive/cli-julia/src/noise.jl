# Noise_IK_25519_ChaChaPoly_BLAKE2s protocol implementation

module NoiseProtocol

include("crypto.jl")
using .NoiseCrypto
using .NoiseCrypto.Blake2s: Blake2s

const PROTOCOL_NAME = b"Noise_IK_25519_ChaChaPoly_BLAKE2s"

# IK pattern:
#   pre-messages:  <- s
#   messages:      -> e, es, s, ss
#                  <- e, ee, se

# ── CipherState ────────────────────────────────────────────────────────────────

mutable struct CipherState
    key::Union{Nothing, Vector{UInt8}}  # 32 bytes or nothing
    nonce::UInt64
end

CipherState() = CipherState(nothing, 0)
CipherState(key::Vector{UInt8}) = CipherState(key, 0)

has_key(cs::CipherState) = cs.key !== nothing

function encrypt_with_ad!(cs::CipherState, ad::Vector{UInt8}, plaintext::Vector{UInt8})::Vector{UInt8}
    cs.key === nothing && return copy(plaintext)
    cs.nonce == typemax(UInt64) && error("nonce exhausted")
    nonce = NoiseCrypto.nonce_bytes(cs.nonce)
    cs.nonce += 1
    NoiseCrypto.aead_encrypt(cs.key, nonce, ad, plaintext)
end

function decrypt_with_ad!(cs::CipherState, ad::Vector{UInt8}, ciphertext::Vector{UInt8})::Vector{UInt8}
    cs.key === nothing && return copy(ciphertext)
    cs.nonce == typemax(UInt64) && error("nonce exhausted")
    nonce = NoiseCrypto.nonce_bytes(cs.nonce)
    cs.nonce += 1
    NoiseCrypto.aead_decrypt(cs.key, nonce, ad, ciphertext)
end

# ── SymmetricState ─────────────────────────────────────────────────────────────

mutable struct SymmetricState
    ck::Vector{UInt8}       # chaining key (32 bytes)
    h::Vector{UInt8}        # handshake hash (32 bytes)
    cipher::CipherState
end

function SymmetricState(protocol_name::Vector{UInt8})
    h = if length(protocol_name) ≤ NoiseCrypto.HASH_LEN
        padded = zeros(UInt8, NoiseCrypto.HASH_LEN)
        copyto!(padded, 1, protocol_name, 1, length(protocol_name))
        padded
    else
        NoiseCrypto.hash(protocol_name)
    end
    SymmetricState(copy(h), h, CipherState())
end

function mix_hash!(ss::SymmetricState, data::AbstractVector{UInt8})
    s = Blake2s.State()
    Blake2s.update!(s, ss.h)
    Blake2s.update!(s, data isa Vector{UInt8} ? data : collect(UInt8, data))
    ss.h = Blake2s.final!(s)
end

function mix_key!(ss::SymmetricState, ikm::Vector{UInt8})
    out1, out2 = NoiseCrypto.hkdf2(ss.ck, ikm)
    ss.ck = out1
    ss.cipher = CipherState(out2)
end

function encrypt_and_hash!(ss::SymmetricState, plaintext::Vector{UInt8})::Vector{UInt8}
    ct = encrypt_with_ad!(ss.cipher, ss.h, plaintext)
    mix_hash!(ss, ct)
    ct
end

function decrypt_and_hash!(ss::SymmetricState, ciphertext::Vector{UInt8})::Vector{UInt8}
    pt = decrypt_with_ad!(ss.cipher, ss.h, ciphertext)
    mix_hash!(ss, ciphertext)
    pt
end

function split(ss::SymmetricState)
    out1, out2 = NoiseCrypto.hkdf2(ss.ck, UInt8[])
    (CipherState(out1), CipherState(out2))
end

# ── TransportState ─────────────────────────────────────────────────────────────

mutable struct TransportState
    send::CipherState
    recv::CipherState
end

function write_transport!(ts::TransportState, plaintext::Vector{UInt8})::Vector{UInt8}
    encrypt_with_ad!(ts.send, UInt8[], plaintext)
end

function read_transport!(ts::TransportState, ciphertext::Vector{UInt8})::Vector{UInt8}
    decrypt_with_ad!(ts.recv, UInt8[], ciphertext)
end

# ── HandshakeState (IK initiator only) ─────────────────────────────────────────

mutable struct HandshakeState
    symmetric::SymmetricState
    s::NoiseCrypto.KeyPair          # local static
    e::Union{Nothing, NoiseCrypto.KeyPair}  # local ephemeral
    rs::Vector{UInt8}               # remote static public (32 bytes)
    re::Union{Nothing, Vector{UInt8}}       # remote ephemeral public
    message_index::Int
    complete::Bool
end

"""Create IK initiator handshake state."""
function HandshakeState(local_keypair::NoiseCrypto.KeyPair, remote_public::Vector{UInt8})
    ss = SymmetricState(collect(UInt8, PROTOCOL_NAME))
    # IK pre-messages: <- s  (responder's static is pre-known)
    mix_hash!(ss, remote_public)
    HandshakeState(ss, local_keypair, nothing, remote_public, nothing, 0, false)
end

"""Write handshake message 1 (initiator -> responder): e, es, s, ss"""
function write_message1!(hs::HandshakeState)::Vector{UInt8}
    hs.message_index == 0 || error("wrong message index")
    out = UInt8[]

    # e: generate ephemeral, send public
    hs.e = NoiseCrypto.generate_keypair()
    append!(out, hs.e.public)
    mix_hash!(hs.symmetric, hs.e.public)

    # es: DH(e, rs)
    dh_result = NoiseCrypto.dh(hs.e.secret, hs.rs)
    mix_key!(hs.symmetric, dh_result)

    # s: encrypt and send static public key
    encrypted_s = encrypt_and_hash!(hs.symmetric, hs.s.public)
    append!(out, encrypted_s)

    # ss: DH(s, rs)
    dh_result = NoiseCrypto.dh(hs.s.secret, hs.rs)
    mix_key!(hs.symmetric, dh_result)

    # Encrypt empty payload
    encrypted_payload = encrypt_and_hash!(hs.symmetric, UInt8[])
    append!(out, encrypted_payload)

    hs.message_index = 1
    out
end

"""Read handshake message 2 (responder -> initiator): e, ee, se"""
function read_message2!(hs::HandshakeState, msg::Vector{UInt8})::Vector{UInt8}
    hs.message_index == 1 || error("wrong message index")
    off = 1  # Julia is 1-indexed

    # e: read remote ephemeral
    off + NoiseCrypto.DH_LEN - 1 ≤ length(msg) || error("truncated message")
    hs.re = msg[off:off + NoiseCrypto.DH_LEN - 1]
    mix_hash!(hs.symmetric, hs.re)
    off += NoiseCrypto.DH_LEN

    # ee: DH(e, re)
    dh_result = NoiseCrypto.dh(hs.e.secret, hs.re)
    mix_key!(hs.symmetric, dh_result)

    # se: DH(s, re)
    dh_result = NoiseCrypto.dh(hs.s.secret, hs.re)
    mix_key!(hs.symmetric, dh_result)

    # Decrypt payload
    payload = decrypt_and_hash!(hs.symmetric, msg[off:end])

    hs.message_index = 2
    hs.complete = true
    payload
end

"""Split into transport state after handshake completes."""
function to_transport(hs::HandshakeState)::TransportState
    hs.complete || error("handshake not complete")
    initiator_cs, responder_cs = split(hs.symmetric)
    TransportState(initiator_cs, responder_cs)
end

end # module
