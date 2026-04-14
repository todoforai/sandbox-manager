# Pure Julia BLAKE2s-256 implementation (RFC 7693)

module Blake2s

const BLOCK_SIZE = 64
const HASH_SIZE = 32

const IV = UInt32[
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
]

const SIGMA = UInt8[
    0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15;
   14 10  4  8  9 15 13  6  1 12  0  2 11  7  5  3;
   11  8 12  0  5  2 15 13 10 14  3  6  7  1  9  4;
    7  9  3  1 13 12 11 14  2  6  5 10  4  0 15  8;
    9  0  5  7  2  4 10 15 14  1 11 12  6  8  3 13;
    2 12  6 10  0 11  8  3  4 13  7  5 15 14  1  9;
   12  5  1 15 14 13  4 10  0  7  6  3  9  2  8 11;
   13 11  7 14 12  1  3  9  5  0 15  4  8  6  2 10;
    6 15 14  9 11  3  0  8 12  2 13  7  1  4 10  5;
   10  2  8  4  7  6  1  5 15 11  9 14  3 12 13  0;
]

mutable struct State
    h::Vector{UInt32}       # 8-word hash state
    t::UInt64               # byte counter
    buf::Vector{UInt8}      # block buffer
    buflen::Int
    outlen::Int
end

function State(; key::Vector{UInt8}=UInt8[], outlen::Int=HASH_SIZE)
    @assert 0 < outlen ≤ HASH_SIZE
    @assert length(key) ≤ HASH_SIZE

    h = copy(IV)
    h[1] ⊻= 0x01010000 ⊻ (UInt32(length(key)) << 8) ⊻ UInt32(outlen)

    s = State(h, UInt64(0), zeros(UInt8, BLOCK_SIZE), 0, outlen)

    if !isempty(key)
        padded = zeros(UInt8, BLOCK_SIZE)
        copyto!(padded, key)
        update!(s, padded)
    end
    s
end

function update!(s::State, data::AbstractVector{UInt8})
    i = 1
    len = length(data)
    while i ≤ len
        if s.buflen == BLOCK_SIZE
            s.t += BLOCK_SIZE
            compress!(s, s.buf, false)
            s.buflen = 0
        end
        n = min(BLOCK_SIZE - s.buflen, len - i + 1)
        copyto!(s.buf, s.buflen + 1, data, i, n)
        s.buflen += n
        i += n
    end
    s
end

function final!(s::State)::Vector{UInt8}
    s.t += s.buflen
    # Pad remaining buffer with zeros
    for i in (s.buflen + 1):BLOCK_SIZE
        s.buf[i] = 0x00
    end
    compress!(s, s.buf, true)
    out = Vector{UInt8}(undef, s.outlen)
    for i in 0:(s.outlen - 1)
        out[i + 1] = UInt8((s.h[(i >> 2) + 1] >> (8 * (i & 3))) & 0xff)
    end
    out
end

@inline function g!(v, a, b, c, d, x, y)
    @inbounds begin
        v[a] = v[a] + v[b] + x
        v[d] = bitrotate(v[d] ⊻ v[a], -16)
        v[c] = v[c] + v[d]
        v[b] = bitrotate(v[b] ⊻ v[c], -12)
        v[a] = v[a] + v[b] + y
        v[d] = bitrotate(v[d] ⊻ v[a], -8)
        v[c] = v[c] + v[d]
        v[b] = bitrotate(v[b] ⊻ v[c], -7)
    end
end

function compress!(s::State, block::Vector{UInt8}, last::Bool)
    # Load message words (little-endian)
    m = Vector{UInt32}(undef, 16)
    @inbounds for i in 0:15
        off = i * 4
        m[i + 1] = UInt32(block[off + 1]) |
                    (UInt32(block[off + 2]) << 8) |
                    (UInt32(block[off + 3]) << 16) |
                    (UInt32(block[off + 4]) << 24)
    end

    v = Vector{UInt32}(undef, 16)
    @inbounds for i in 1:8
        v[i] = s.h[i]
    end
    @inbounds for i in 1:8
        v[8 + i] = IV[i]
    end
    v[13] ⊻= UInt32(s.t & 0xffffffff)
    v[14] ⊻= UInt32((s.t >> 32) & 0xffffffff)
    if last
        v[15] ⊻= 0xffffffff
    end

    # 10 rounds
    for round in 1:10
        σ = @view SIGMA[round, :]
        # Column step
        g!(v, 1, 5,  9, 13, m[σ[ 1] + 1], m[σ[ 2] + 1])
        g!(v, 2, 6, 10, 14, m[σ[ 3] + 1], m[σ[ 4] + 1])
        g!(v, 3, 7, 11, 15, m[σ[ 5] + 1], m[σ[ 6] + 1])
        g!(v, 4, 8, 12, 16, m[σ[ 7] + 1], m[σ[ 8] + 1])
        # Diagonal step
        g!(v, 1, 6, 11, 16, m[σ[ 9] + 1], m[σ[10] + 1])
        g!(v, 2, 7, 12, 13, m[σ[11] + 1], m[σ[12] + 1])
        g!(v, 3, 8,  9, 14, m[σ[13] + 1], m[σ[14] + 1])
        g!(v, 4, 5, 10, 15, m[σ[15] + 1], m[σ[16] + 1])
    end

    @inbounds for i in 1:8
        s.h[i] ⊻= v[i] ⊻ v[8 + i]
    end
end

"""Hash data in one shot, returning 32-byte digest."""
function hash(data::AbstractVector{UInt8})::Vector{UInt8}
    s = State()
    update!(s, data)
    final!(s)
end

end # module
