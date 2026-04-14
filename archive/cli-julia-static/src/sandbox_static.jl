# StaticCompiler-compatible sandbox CLI
# Noise_IK_25519_ChaChaPoly_BLAKE2s over TCP
#
# All memory: malloc/calloc/free (no GC)
# All I/O: POSIX syscalls via @symbolcall
# All crypto: libsodium via @symbolcall + pure Julia BLAKE2s
# No Julia runtime, no strings, no arrays — just pointers and integers.

using StaticCompiler, StaticTools

# ── Constants ──────────────────────────────────────────────────────────────────

const AF_INET     = Int32(2)
const SOCK_STREAM = Int32(1)
const DH_LEN      = 32
const KEY_LEN     = 32
const HASH_LEN    = 32
const NONCE_LEN   = 12
const TAG_LEN     = 16
const MAX_FRAME   = 1024 * 1024
const BLOCK_SIZE  = 64

# ── POSIX wrappers ─────────────────────────────────────────────────────────────

@inline sock_socket() = @symbolcall socket(AF_INET::Int32, SOCK_STREAM::Int32, Int32(0)::Int32)::Int32
@inline sock_connect(fd::Int32, addr::Ptr{UInt8}, len::Int32) = @symbolcall connect(fd::Int32, addr::Ptr{UInt8}, len::Int32)::Int32
@inline sock_close(fd::Int32) = @symbolcall close(fd::Int32)::Int32
@inline sock_htons(x::UInt16) = @symbolcall htons(x::UInt16)::UInt16
@inline sock_htonl(x::UInt32) = @symbolcall htonl(x::UInt32)::UInt32
@inline sock_ntohl(x::UInt32) = @symbolcall ntohl(x::UInt32)::UInt32

@inline function sock_write(fd::Int32, buf::Ptr{UInt8}, len::Int)
    written = Int(0)
    while written < len
        n = @symbolcall write(fd::Int32, (buf + written)::Ptr{UInt8}, (len - written)::Int)::Int
        n <= 0 && return Int32(-1)
        written += n
    end
    return Int32(0)
end

@inline function sock_read_exact(fd::Int32, buf::Ptr{UInt8}, len::Int)
    got = Int(0)
    while got < len
        n = @symbolcall read(fd::Int32, (buf + got)::Ptr{UInt8}, (len - got)::Int)::Int
        n <= 0 && return Int32(-1)
        got += n
    end
    return Int32(0)
end

@inline function getenv_ptr(name)
    @symbolcall getenv(Ptr{UInt8}(pointer(name))::Ptr{UInt8})::Ptr{UInt8}
end

@inline function strlen_c(s::Ptr{UInt8})
    @symbolcall strlen(s::Ptr{UInt8})::Int
end

# ── Framing ────────────────────────────────────────────────────────────────────

@inline function write_frame(fd::Int32, data::Ptr{UInt8}, len::Int)
    len_buf = calloc(4)
    unsafe_store!(Ptr{UInt32}(len_buf), sock_htonl(UInt32(len)))
    ret = sock_write(fd, len_buf, Int(4))
    free(len_buf)
    ret < Int32(0) && return Int32(-1)
    sock_write(fd, data, len)
end

# Returns (ptr, len) — caller must free ptr. Returns (Ptr{UInt8}(0), 0) on error.
@inline function read_frame(fd::Int32)
    len_buf = calloc(4)
    ret = sock_read_exact(fd, len_buf, Int(4))
    if ret < Int32(0)
        free(len_buf)
        return (Ptr{UInt8}(0), Int(0))
    end
    len = Int(sock_ntohl(unsafe_load(Ptr{UInt32}(len_buf))))
    free(len_buf)
    (len <= 0 || len > MAX_FRAME) && return (Ptr{UInt8}(0), Int(0))
    buf = malloc(len)
    ret = sock_read_exact(fd, buf, len)
    if ret < Int32(0)
        free(buf)
        return (Ptr{UInt8}(0), Int(0))
    end
    return (buf, len)
end

# ── BLAKE2s-256 (pure Julia, pointer-based) ────────────────────────────────────

const BLAKE2S_IV = (
    UInt32(0x6A09E667), UInt32(0xBB67AE85), UInt32(0x3C6EF372), UInt32(0xA54FF53A),
    UInt32(0x510E527F), UInt32(0x9B05688C), UInt32(0x1F83D9AB), UInt32(0x5BE0CD19),
)

const BLAKE2S_SIGMA = (
    ( 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15),
    (14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3),
    (11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4),
    ( 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8),
    ( 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13),
    ( 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9),
    (12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11),
    (13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10),
    ( 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5),
    (10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0),
)

# BLAKE2s state: h[8] + t(u64) + buf[64] + buflen + outlen = 8*4+8+64+4+4 = 112 bytes
# Layout: [h:32][t:8][buf:64][buflen:4][outlen:4] = 112 bytes
const B2S_OFF_H      = 0
const B2S_OFF_T      = 32
const B2S_OFF_BUF    = 40
const B2S_OFF_BUFLEN = 104
const B2S_OFF_OUTLEN = 108
const B2S_SIZE       = 112

@inline function b2s_init(outlen::Int32)
    s = calloc(B2S_SIZE)
    # Copy IV
    for i in 0:7
        unsafe_store!(Ptr{UInt32}(s + B2S_OFF_H + i*4), BLAKE2S_IV[i+1])
    end
    # XOR parameter block into h[0]
    h0 = unsafe_load(Ptr{UInt32}(s + B2S_OFF_H))
    h0 ⊻= UInt32(0x01010000) ⊻ UInt32(outlen)
    unsafe_store!(Ptr{UInt32}(s + B2S_OFF_H), h0)
    unsafe_store!(Ptr{Int32}(s + B2S_OFF_OUTLEN), outlen)
    return s
end

@inline function b2s_load32(p::Ptr{UInt8}, off::Int)
    UInt32(unsafe_load(p, off+1)) |
    (UInt32(unsafe_load(p, off+2)) << 8) |
    (UInt32(unsafe_load(p, off+3)) << 16) |
    (UInt32(unsafe_load(p, off+4)) << 24)
end

@inline function b2s_compress!(s::Ptr{UInt8}, block::Ptr{UInt8}, last::Bool)
    # Load message words
    v = calloc(64)  # 16 x UInt32
    m = calloc(64)  # 16 x UInt32
    for i in 0:15
        unsafe_store!(Ptr{UInt32}(m + i*4), b2s_load32(block, i*4))
    end
    for i in 0:7
        unsafe_store!(Ptr{UInt32}(v + i*4), unsafe_load(Ptr{UInt32}(s + B2S_OFF_H + i*4)))
    end
    for i in 0:7
        unsafe_store!(Ptr{UInt32}(v + (8+i)*4), BLAKE2S_IV[i+1])
    end
    t = unsafe_load(Ptr{UInt64}(s + B2S_OFF_T))
    v12 = unsafe_load(Ptr{UInt32}(v + 12*4)) ⊻ UInt32(t & 0xffffffff)
    unsafe_store!(Ptr{UInt32}(v + 12*4), v12)
    v13 = unsafe_load(Ptr{UInt32}(v + 13*4)) ⊻ UInt32((t >> 32) & 0xffffffff)
    unsafe_store!(Ptr{UInt32}(v + 13*4), v13)
    if last
        v14 = unsafe_load(Ptr{UInt32}(v + 14*4)) ⊻ UInt32(0xffffffff)
        unsafe_store!(Ptr{UInt32}(v + 14*4), v14)
    end

    for round in 1:10
        σ = BLAKE2S_SIGMA[round]
        b2s_g!(v, m, 0, 4,  8, 12, σ[ 1]+1, σ[ 2]+1)
        b2s_g!(v, m, 1, 5,  9, 13, σ[ 3]+1, σ[ 4]+1)
        b2s_g!(v, m, 2, 6, 10, 14, σ[ 5]+1, σ[ 6]+1)
        b2s_g!(v, m, 3, 7, 11, 15, σ[ 7]+1, σ[ 8]+1)
        b2s_g!(v, m, 0, 5, 10, 15, σ[ 9]+1, σ[10]+1)
        b2s_g!(v, m, 1, 6, 11, 12, σ[11]+1, σ[12]+1)
        b2s_g!(v, m, 2, 7,  8, 13, σ[13]+1, σ[14]+1)
        b2s_g!(v, m, 3, 4,  9, 14, σ[15]+1, σ[16]+1)
    end

    for i in 0:7
        h = unsafe_load(Ptr{UInt32}(s + B2S_OFF_H + i*4))
        h ⊻= unsafe_load(Ptr{UInt32}(v + i*4)) ⊻ unsafe_load(Ptr{UInt32}(v + (8+i)*4))
        unsafe_store!(Ptr{UInt32}(s + B2S_OFF_H + i*4), h)
    end
    free(v)
    free(m)
end

@inline function b2s_g!(v::Ptr{UInt8}, m::Ptr{UInt8}, a::Int, b::Int, c::Int, d::Int, xi::Int, yi::Int)
    va = unsafe_load(Ptr{UInt32}(v + a*4))
    vb = unsafe_load(Ptr{UInt32}(v + b*4))
    vc = unsafe_load(Ptr{UInt32}(v + c*4))
    vd = unsafe_load(Ptr{UInt32}(v + d*4))
    x = unsafe_load(Ptr{UInt32}(m + (xi-1)*4))
    y = unsafe_load(Ptr{UInt32}(m + (yi-1)*4))

    va = va + vb + x
    vd = bitrotate(vd ⊻ va, -16)
    vc = vc + vd
    vb = bitrotate(vb ⊻ vc, -12)
    va = va + vb + y
    vd = bitrotate(vd ⊻ va, -8)
    vc = vc + vd
    vb = bitrotate(vb ⊻ vc, -7)

    unsafe_store!(Ptr{UInt32}(v + a*4), va)
    unsafe_store!(Ptr{UInt32}(v + b*4), vb)
    unsafe_store!(Ptr{UInt32}(v + c*4), vc)
    unsafe_store!(Ptr{UInt32}(v + d*4), vd)
end

@inline function b2s_update!(s::Ptr{UInt8}, data::Ptr{UInt8}, len::Int)
    buflen = Int(unsafe_load(Ptr{Int32}(s + B2S_OFF_BUFLEN)))
    i = 0
    while i < len
        if buflen == BLOCK_SIZE
            t = unsafe_load(Ptr{UInt64}(s + B2S_OFF_T)) + UInt64(BLOCK_SIZE)
            unsafe_store!(Ptr{UInt64}(s + B2S_OFF_T), t)
            b2s_compress!(s, s + B2S_OFF_BUF, false)
            buflen = 0
        end
        n = min(BLOCK_SIZE - buflen, len - i)
        memcpy!(s + B2S_OFF_BUF + buflen, data + i, Int64(n))
        buflen += n
        i += n
    end
    unsafe_store!(Ptr{Int32}(s + B2S_OFF_BUFLEN), Int32(buflen))
end

# Returns malloc'd 32-byte hash. Frees state.
@inline function b2s_final!(s::Ptr{UInt8})
    buflen = Int(unsafe_load(Ptr{Int32}(s + B2S_OFF_BUFLEN)))
    outlen = Int(unsafe_load(Ptr{Int32}(s + B2S_OFF_OUTLEN)))
    t = unsafe_load(Ptr{UInt64}(s + B2S_OFF_T)) + UInt64(buflen)
    unsafe_store!(Ptr{UInt64}(s + B2S_OFF_T), t)
    # Zero-pad remaining buffer
    for j in buflen:(BLOCK_SIZE-1)
        unsafe_store!(s + B2S_OFF_BUF + j, UInt8(0))
    end
    b2s_compress!(s, s + B2S_OFF_BUF, true)
    out = malloc(outlen)
    for i in 0:(outlen-1)
        out_byte = UInt8((unsafe_load(Ptr{UInt32}(s + B2S_OFF_H + (i >> 2)*4)) >> (8 * (i & 3))) & 0xff)
        unsafe_store!(out + i, out_byte)
    end
    free(s)
    return out
end

# One-shot hash. Returns malloc'd 32 bytes.
@inline function b2s_hash(data::Ptr{UInt8}, len::Int)
    s = b2s_init(Int32(HASH_LEN))
    b2s_update!(s, data, len)
    b2s_final!(s)
end

# ── HMAC-BLAKE2s ───────────────────────────────────────────────────────────────

# Returns malloc'd 32 bytes.
@inline function hmac_b2s(key::Ptr{UInt8}, keylen::Int, data::Ptr{UInt8}, datalen::Int)
    padded = calloc(BLOCK_SIZE)
    if keylen > BLOCK_SIZE
        h = b2s_hash(key, keylen)
        memcpy!(padded, h, Int64(HASH_LEN))
        free(h)
    else
        memcpy!(padded, key, Int64(keylen))
    end

    ipad = malloc(BLOCK_SIZE)
    opad = malloc(BLOCK_SIZE)
    for i in 0:(BLOCK_SIZE-1)
        b = unsafe_load(padded + i)
        unsafe_store!(ipad + i, b ⊻ UInt8(0x36))
        unsafe_store!(opad + i, b ⊻ UInt8(0x5c))
    end
    free(padded)

    # Inner: H(ipad || data)
    inner = b2s_init(Int32(HASH_LEN))
    b2s_update!(inner, ipad, BLOCK_SIZE)
    b2s_update!(inner, data, datalen)
    inner_hash = b2s_final!(inner)
    free(ipad)

    # Outer: H(opad || inner_hash)
    outer = b2s_init(Int32(HASH_LEN))
    b2s_update!(outer, opad, BLOCK_SIZE)
    b2s_update!(outer, inner_hash, HASH_LEN)
    result = b2s_final!(outer)
    free(opad)
    free(inner_hash)
    return result
end

# ── HKDF ───────────────────────────────────────────────────────────────────────

# hkdf2: returns (out1, out2) — both malloc'd 32 bytes
@inline function hkdf2(ck::Ptr{UInt8}, ikm::Ptr{UInt8}, ikmlen::Int)
    prk = hmac_b2s(ck, HASH_LEN, ikm, ikmlen)
    tag1 = malloc(1); unsafe_store!(tag1, UInt8(0x01))
    out1 = hmac_b2s(prk, HASH_LEN, tag1, 1)
    free(tag1)
    # out2 = HMAC(prk, out1 || 0x02)
    tmp = malloc(HASH_LEN + 1)
    memcpy!(tmp, out1, Int64(HASH_LEN))
    unsafe_store!(tmp + HASH_LEN, UInt8(0x02))
    out2 = hmac_b2s(prk, HASH_LEN, tmp, HASH_LEN + 1)
    free(tmp)
    free(prk)
    return (out1, out2)
end

# ── Libsodium wrappers ────────────────────────────────────────────────────────

@inline sodium_init() = @symbolcall sodium_init()::Int32

@inline function x25519_base(pub::Ptr{UInt8}, sec::Ptr{UInt8})
    @symbolcall crypto_scalarmult_curve25519_base(pub::Ptr{UInt8}, sec::Ptr{UInt8})::Int32
end

@inline function x25519(out::Ptr{UInt8}, sec::Ptr{UInt8}, pub::Ptr{UInt8})
    @symbolcall crypto_scalarmult_curve25519(out::Ptr{UInt8}, sec::Ptr{UInt8}, pub::Ptr{UInt8})::Int32
end

@inline function randombytes(buf::Ptr{UInt8}, len::Int)
    @symbolcall randombytes_buf(buf::Ptr{UInt8}, len::UInt)::Nothing
end

@inline function aead_encrypt(ct::Ptr{UInt8}, tag::Ptr{UInt8}, pt::Ptr{UInt8}, ptlen::Int,
                               ad::Ptr{UInt8}, adlen::Int, nonce::Ptr{UInt8}, key::Ptr{UInt8})
    maclen = calloc(8)
    ret = @symbolcall crypto_aead_chacha20poly1305_ietf_encrypt_detached(
        ct::Ptr{UInt8}, tag::Ptr{UInt8}, maclen::Ptr{UInt8},
        pt::Ptr{UInt8}, UInt64(ptlen)::UInt64,
        ad::Ptr{UInt8}, UInt64(adlen)::UInt64,
        Ptr{UInt8}(0)::Ptr{UInt8}, nonce::Ptr{UInt8}, key::Ptr{UInt8})::Int32
    free(maclen)
    return ret
end

@inline function aead_decrypt(pt::Ptr{UInt8}, ct::Ptr{UInt8}, ctlen::Int,
                               tag::Ptr{UInt8}, ad::Ptr{UInt8}, adlen::Int,
                               nonce::Ptr{UInt8}, key::Ptr{UInt8})
    @symbolcall crypto_aead_chacha20poly1305_ietf_decrypt_detached(
        pt::Ptr{UInt8}, Ptr{UInt8}(0)::Ptr{UInt8},
        ct::Ptr{UInt8}, UInt64(ctlen)::UInt64,
        tag::Ptr{UInt8}, ad::Ptr{UInt8}, UInt64(adlen)::UInt64,
        nonce::Ptr{UInt8}, key::Ptr{UInt8})::Int32
end

@inline function make_nonce(n::UInt64)
    buf = calloc(NONCE_LEN)
    for i in 0:7
        unsafe_store!(buf + 4 + i, UInt8((n >> (8*i)) & 0xff))
    end
    buf
end

# ── Noise CipherState ─────────────────────────────────────────────────────────
# Layout: [key:32][has_key:1][pad:3][nonce:8] = 44 bytes
const CS_OFF_KEY     = 0
const CS_OFF_HASKEY  = 32
const CS_OFF_NONCE   = 36
const CS_SIZE        = 44

@inline function cs_new()
    calloc(CS_SIZE)  # has_key = 0
end

@inline function cs_new_with_key(key::Ptr{UInt8})
    cs = calloc(CS_SIZE)
    memcpy!(cs + CS_OFF_KEY, key, Int64(KEY_LEN))
    unsafe_store!(Ptr{Int32}(cs + CS_OFF_HASKEY), Int32(1))
    return cs
end

@inline cs_has_key(cs::Ptr{UInt8}) = unsafe_load(Ptr{Int32}(cs + CS_OFF_HASKEY)) != Int32(0)
@inline cs_nonce(cs::Ptr{UInt8}) = unsafe_load(Ptr{UInt64}(cs + CS_OFF_NONCE))

@inline function cs_inc_nonce!(cs::Ptr{UInt8})
    n = cs_nonce(cs) + UInt64(1)
    unsafe_store!(Ptr{UInt64}(cs + CS_OFF_NONCE), n)
end

# Encrypt: returns (ct_ptr, ct_len). Caller frees ct_ptr.
@inline function cs_encrypt!(cs::Ptr{UInt8}, ad::Ptr{UInt8}, adlen::Int, pt::Ptr{UInt8}, ptlen::Int)
    if !cs_has_key(cs)
        out = malloc(ptlen)
        memcpy!(out, pt, Int64(ptlen))
        return (out, ptlen)
    end
    nonce = make_nonce(cs_nonce(cs))
    ct = malloc(ptlen + TAG_LEN)
    tag = ct + ptlen
    aead_encrypt(ct, tag, pt, ptlen, ad, adlen, nonce, cs + CS_OFF_KEY)
    free(nonce)
    cs_inc_nonce!(cs)
    return (ct, ptlen + TAG_LEN)
end

# Decrypt: returns (pt_ptr, pt_len). Caller frees pt_ptr. pt_len = -1 on error.
@inline function cs_decrypt!(cs::Ptr{UInt8}, ad::Ptr{UInt8}, adlen::Int, ct::Ptr{UInt8}, ctlen::Int)
    if !cs_has_key(cs)
        out = malloc(ctlen)
        memcpy!(out, ct, Int64(ctlen))
        return (out, ctlen)
    end
    ctlen < TAG_LEN && return (Ptr{UInt8}(0), -1)
    msglen = ctlen - TAG_LEN
    nonce = make_nonce(cs_nonce(cs))
    pt = malloc(msglen)
    ret = aead_decrypt(pt, ct, msglen, ct + msglen, ad, adlen, nonce, cs + CS_OFF_KEY)
    free(nonce)
    if ret != Int32(0)
        free(pt)
        return (Ptr{UInt8}(0), -1)
    end
    cs_inc_nonce!(cs)
    return (pt, msglen)
end

# ── Noise SymmetricState ───────────────────────────────────────────────────────
# Layout: [ck:32][h:32][cipher:CS_SIZE] = 108 bytes
const SS_OFF_CK     = 0
const SS_OFF_H      = 32
const SS_OFF_CIPHER = 64
const SS_SIZE       = 64 + CS_SIZE

@inline function ss_new()
    ss = calloc(SS_SIZE)
    # Protocol name = "Noise_IK_25519_ChaChaPoly_BLAKE2s" (33 bytes > 32, so hash it)
    pname = c"Noise_IK_25519_ChaChaPoly_BLAKE2s"
    h = b2s_hash(Ptr{UInt8}(pointer(pname)), 33)
    memcpy!(ss + SS_OFF_CK, h, Int64(HASH_LEN))
    memcpy!(ss + SS_OFF_H, h, Int64(HASH_LEN))
    free(h)
    return ss
end

@inline function ss_mix_hash!(ss::Ptr{UInt8}, data::Ptr{UInt8}, len::Int)
    s = b2s_init(Int32(HASH_LEN))
    b2s_update!(s, ss + SS_OFF_H, HASH_LEN)
    b2s_update!(s, data, len)
    h = b2s_final!(s)
    memcpy!(ss + SS_OFF_H, h, Int64(HASH_LEN))
    free(h)
end

@inline function ss_mix_key!(ss::Ptr{UInt8}, ikm::Ptr{UInt8}, ikmlen::Int)
    out1, out2 = hkdf2(ss + SS_OFF_CK, ikm, ikmlen)
    memcpy!(ss + SS_OFF_CK, out1, Int64(HASH_LEN))
    # Set cipher key
    memcpy!(ss + SS_OFF_CIPHER + CS_OFF_KEY, out2, Int64(KEY_LEN))
    unsafe_store!(Ptr{Int32}(ss + SS_OFF_CIPHER + CS_OFF_HASKEY), Int32(1))
    unsafe_store!(Ptr{UInt64}(ss + SS_OFF_CIPHER + CS_OFF_NONCE), UInt64(0))
    free(out1)
    free(out2)
end

# Returns (ct_ptr, ct_len)
@inline function ss_encrypt_and_hash!(ss::Ptr{UInt8}, pt::Ptr{UInt8}, ptlen::Int)
    ct, ctlen = cs_encrypt!(ss + SS_OFF_CIPHER, ss + SS_OFF_H, HASH_LEN, pt, ptlen)
    ss_mix_hash!(ss, ct, ctlen)
    return (ct, ctlen)
end

# Returns (pt_ptr, pt_len)
@inline function ss_decrypt_and_hash!(ss::Ptr{UInt8}, ct::Ptr{UInt8}, ctlen::Int)
    pt, ptlen = cs_decrypt!(ss + SS_OFF_CIPHER, ss + SS_OFF_H, HASH_LEN, ct, ctlen)
    ss_mix_hash!(ss, ct, ctlen)
    return (pt, ptlen)
end

# ── Noise IK Handshake (initiator) ────────────────────────────────────────────

# Perform full IK handshake. Returns (send_cs, recv_cs) or (null, null) on error.
@inline function noise_handshake!(fd::Int32, local_sec::Ptr{UInt8}, local_pub::Ptr{UInt8}, remote_pub::Ptr{UInt8})
    ss = ss_new()

    # Pre-message: <- s (mix remote static public)
    ss_mix_hash!(ss, remote_pub, DH_LEN)

    # === msg1: -> e, es, s, ss ===
    msg1 = malloc(256)
    msg1_len = 0

    # e: generate ephemeral
    e_sec = malloc(32); e_pub = malloc(32)
    randombytes(e_sec, 32)
    x25519_base(e_pub, e_sec)
    memcpy!(msg1, e_pub, Int64(DH_LEN))
    ss_mix_hash!(ss, e_pub, DH_LEN)
    msg1_len += DH_LEN

    # es: DH(e, rs)
    dh_out = malloc(32)
    x25519(dh_out, e_sec, remote_pub)
    ss_mix_key!(ss, dh_out, DH_LEN)
    free(dh_out)

    # s: encrypt local static public
    enc_s, enc_s_len = ss_encrypt_and_hash!(ss, local_pub, DH_LEN)
    memcpy!(msg1 + msg1_len, enc_s, Int64(enc_s_len))
    msg1_len += enc_s_len
    free(enc_s)

    # ss: DH(s, rs)
    dh_out = malloc(32)
    x25519(dh_out, local_sec, remote_pub)
    ss_mix_key!(ss, dh_out, DH_LEN)
    free(dh_out)

    # Encrypt empty payload
    enc_p, enc_p_len = ss_encrypt_and_hash!(ss, Ptr{UInt8}(0), 0)
    memcpy!(msg1 + msg1_len, enc_p, Int64(enc_p_len))
    msg1_len += enc_p_len
    free(enc_p)

    # Send msg1
    write_frame(fd, msg1, msg1_len)
    free(msg1)

    # === msg2: <- e, ee, se ===
    msg2, msg2_len = read_frame(fd)
    if msg2 == Ptr{UInt8}(0)
        free(e_sec); free(e_pub); free(ss)
        return (Ptr{UInt8}(0), Ptr{UInt8}(0))
    end

    off = 0
    # e: read remote ephemeral
    re_pub = malloc(DH_LEN)
    memcpy!(re_pub, msg2, Int64(DH_LEN))
    ss_mix_hash!(ss, re_pub, DH_LEN)
    off += DH_LEN

    # ee: DH(e, re)
    dh_out = malloc(32)
    x25519(dh_out, e_sec, re_pub)
    ss_mix_key!(ss, dh_out, DH_LEN)
    free(dh_out)

    # se: DH(s, re)
    dh_out = malloc(32)
    x25519(dh_out, local_sec, re_pub)
    ss_mix_key!(ss, dh_out, DH_LEN)
    free(dh_out)

    # Decrypt payload
    pt, ptlen = ss_decrypt_and_hash!(ss, msg2 + off, msg2_len - off)
    if ptlen < 0
        free(e_sec); free(e_pub); free(re_pub); free(msg2); free(ss)
        return (Ptr{UInt8}(0), Ptr{UInt8}(0))
    end
    if ptlen > 0; free(pt); end
    free(re_pub); free(e_sec); free(e_pub); free(msg2)

    # Split
    out1, out2 = hkdf2(ss + SS_OFF_CK, Ptr{UInt8}(0), 0)
    send_cs = cs_new_with_key(out1)
    recv_cs = cs_new_with_key(out2)
    free(out1); free(out2); free(ss)
    return (send_cs, recv_cs)
end

# ── Hex decode ─────────────────────────────────────────────────────────────────

@inline function hexval(c::UInt8)
    c >= UInt8('0') && c <= UInt8('9') && return Int32(c - UInt8('0'))
    c >= UInt8('a') && c <= UInt8('f') && return Int32(c - UInt8('a') + 10)
    c >= UInt8('A') && c <= UInt8('F') && return Int32(c - UInt8('A') + 10)
    return Int32(-1)
end

@inline function hex_decode(hex::Ptr{UInt8}, hexlen::Int, out::Ptr{UInt8})
    for i in 0:2:(hexlen-1)
        hi = hexval(unsafe_load(hex, i+1))
        lo = hexval(unsafe_load(hex, i+2))
        (hi < Int32(0) || lo < Int32(0)) && return Int32(-1)
        unsafe_store!(out + (i >> 1), UInt8((hi << 4) | lo))
    end
    return Int32(0)
end

@inline function hex_encode(data::Ptr{UInt8}, len::Int, out::Ptr{UInt8})
    hex_chars = c"0123456789abcdef"
    for i in 0:(len-1)
        b = unsafe_load(data + i)
        unsafe_store!(out + i*2, unsafe_load(Ptr{UInt8}(pointer(hex_chars)), Int(b >> 4) + 1))
        unsafe_store!(out + i*2 + 1, unsafe_load(Ptr{UInt8}(pointer(hex_chars)), Int(b & 0x0f) + 1))
    end
end

# ── Minimal JSON builder ──────────────────────────────────────────────────────

@inline function json_request(id::Ptr{UInt8}, idlen::Int, kind::Ptr{UInt8}, kindlen::Int, 
                               payload::Ptr{UInt8}, payloadlen::Int)
    # {"id":"...","type":"...","payload":...}
    total = 30 + idlen + kindlen + payloadlen  # generous
    buf = malloc(total)
    pos = 0
    
    prefix = c"{\"id\":\""
    n = 7; memcpy!(buf + pos, Ptr{UInt8}(pointer(prefix)), Int64(n)); pos += n
    memcpy!(buf + pos, id, Int64(idlen)); pos += idlen
    mid1 = c"\",\"type\":\""
    n = 10; memcpy!(buf + pos, Ptr{UInt8}(pointer(mid1)), Int64(n)); pos += n
    memcpy!(buf + pos, kind, Int64(kindlen)); pos += kindlen
    mid2 = c"\",\"payload\":"
    n = 12; memcpy!(buf + pos, Ptr{UInt8}(pointer(mid2)), Int64(n)); pos += n
    memcpy!(buf + pos, payload, Int64(payloadlen)); pos += payloadlen
    unsafe_store!(buf + pos, UInt8('}')); pos += 1
    
    return (buf, pos)
end

# ── Main ───────────────────────────────────────────────────────────────────────

function sandbox_main(argc::Int, argv::Ptr{Ptr{UInt8}})
    sodium_init()

    argc < 2 && (printf(c"Usage: sandbox <health|stats|list|get|delete|pause|resume|create|template>\n"); return Int32(1))

    cmd = unsafe_load(argv, 2)  # argv[1]

    # Load keys
    priv_hex = getenv_ptr(c"NOISE_LOCAL_PRIVATE_KEY")
    pub_hex = getenv_ptr(c"NOISE_REMOTE_PUBLIC_KEY")
    if priv_hex == Ptr{UInt8}(0) || pub_hex == Ptr{UInt8}(0)
        printf(c"error: NOISE_LOCAL_PRIVATE_KEY and NOISE_REMOTE_PUBLIC_KEY must be set\n")
        return Int32(1)
    end

    local_sec = malloc(32)
    hex_decode(priv_hex, 64, local_sec)
    local_pub = malloc(32)
    x25519_base(local_pub, local_sec)
    remote_pub = malloc(32)
    hex_decode(pub_hex, 64, remote_pub)

    # Resolve address
    addr_env = getenv_ptr(c"NOISE_ADDR")
    host = UInt32(0x7f000001)  # 127.0.0.1
    port = UInt16(9001)
    # TODO: parse NOISE_ADDR if set

    # Connect
    fd = sock_socket()
    if fd < Int32(0)
        printf(c"error: socket() failed\n")
        return Int32(1)
    end
    sa = calloc(16)
    unsafe_store!(Ptr{UInt16}(sa), UInt16(AF_INET))
    unsafe_store!(Ptr{UInt16}(sa + 2), sock_htons(port))
    unsafe_store!(Ptr{UInt32}(sa + 4), sock_htonl(host))
    ret = sock_connect(fd, sa, Int32(16))
    free(sa)
    if ret < Int32(0)
        printf(c"error: connect failed\n")
        sock_close(fd)
        return Int32(1)
    end

    # Handshake
    send_cs, recv_cs = noise_handshake!(fd, local_sec, local_pub, remote_pub)
    free(local_sec); free(local_pub); free(remote_pub)
    if send_cs == Ptr{UInt8}(0)
        printf(c"error: handshake failed\n")
        sock_close(fd)
        return Int32(1)
    end

    # Determine request type
    kind = Ptr{UInt8}(pointer(c"health.get"))
    kindlen = 10
    payload = Ptr{UInt8}(pointer(c"{}"))
    payloadlen = 2

    # Simple command dispatch (compare first char for speed)
    c0 = unsafe_load(cmd, 1)
    if c0 == UInt8('s')  # stats
        kind = Ptr{UInt8}(pointer(c"stats.get")); kindlen = 9
    elseif c0 == UInt8('l')  # list
        kind = Ptr{UInt8}(pointer(c"sandbox.list")); kindlen = 12
    elseif c0 == UInt8('g')  # get
        if argc >= 3
            kind = Ptr{UInt8}(pointer(c"sandbox.get")); kindlen = 11
            # Build {"id":"..."}
            id_arg = unsafe_load(argv, 3)
            id_len = strlen_c(id_arg)
            payload_buf = malloc(10 + id_len)
            p = c"{\"id\":\""; memcpy!(payload_buf, Ptr{UInt8}(pointer(p)), Int64(7))
            memcpy!(payload_buf + 7, id_arg, Int64(id_len))
            unsafe_store!(payload_buf + 7 + id_len, UInt8('"'))
            unsafe_store!(payload_buf + 8 + id_len, UInt8('}'))
            payload = payload_buf
            payloadlen = 9 + id_len
        end
    elseif c0 == UInt8('d')  # delete
        if argc >= 3
            kind = Ptr{UInt8}(pointer(c"sandbox.delete")); kindlen = 14
            id_arg = unsafe_load(argv, 3)
            id_len = strlen_c(id_arg)
            payload_buf = malloc(10 + id_len)
            p = c"{\"id\":\""; memcpy!(payload_buf, Ptr{UInt8}(pointer(p)), Int64(7))
            memcpy!(payload_buf + 7, id_arg, Int64(id_len))
            unsafe_store!(payload_buf + 7 + id_len, UInt8('"'))
            unsafe_store!(payload_buf + 8 + id_len, UInt8('}'))
            payload = payload_buf
            payloadlen = 9 + id_len
        end
    elseif c0 == UInt8('p')  # pause
        if argc >= 3
            kind = Ptr{UInt8}(pointer(c"sandbox.pause")); kindlen = 13
            id_arg = unsafe_load(argv, 3)
            id_len = strlen_c(id_arg)
            payload_buf = malloc(10 + id_len)
            p = c"{\"id\":\""; memcpy!(payload_buf, Ptr{UInt8}(pointer(p)), Int64(7))
            memcpy!(payload_buf + 7, id_arg, Int64(id_len))
            unsafe_store!(payload_buf + 7 + id_len, UInt8('"'))
            unsafe_store!(payload_buf + 8 + id_len, UInt8('}'))
            payload = payload_buf
            payloadlen = 9 + id_len
        end
    elseif c0 == UInt8('r')  # resume
        if argc >= 3
            kind = Ptr{UInt8}(pointer(c"sandbox.resume")); kindlen = 14
            id_arg = unsafe_load(argv, 3)
            id_len = strlen_c(id_arg)
            payload_buf = malloc(10 + id_len)
            p = c"{\"id\":\""; memcpy!(payload_buf, Ptr{UInt8}(pointer(p)), Int64(7))
            memcpy!(payload_buf + 7, id_arg, Int64(id_len))
            unsafe_store!(payload_buf + 7 + id_len, UInt8('"'))
            unsafe_store!(payload_buf + 8 + id_len, UInt8('}'))
            payload = payload_buf
            payloadlen = 9 + id_len
        end
    end

    # Build request JSON
    req_id = malloc(8)
    id_bytes = malloc(4)
    randombytes(id_bytes, 4)
    hex_encode(id_bytes, 4, req_id)
    free(id_bytes)

    req_json, req_len = json_request(req_id, 8, kind, kindlen, payload, payloadlen)
    free(req_id)

    # Encrypt and send
    enc, enclen = cs_encrypt!(send_cs, Ptr{UInt8}(0), 0, req_json, req_len)
    free(req_json)
    write_frame(fd, enc, enclen)
    free(enc)

    # Receive and decrypt
    resp_enc, resp_enclen = read_frame(fd)
    if resp_enc != Ptr{UInt8}(0)
        resp, resplen = cs_decrypt!(recv_cs, Ptr{UInt8}(0), 0, resp_enc, resp_enclen)
        free(resp_enc)
        if resplen > 0
            # Write response to stdout
            @symbolcall write(Int32(1)::Int32, resp::Ptr{UInt8}, resplen::Int)::Int
            printf(c"\n")
            free(resp)
        else
            printf(c"error: decrypt failed\n")
        end
    else
        printf(c"error: no response\n")
    end

    free(send_cs); free(recv_cs)
    sock_close(fd)
    return Int32(0)
end
