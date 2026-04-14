// Noise_IK_25519_ChaChaPoly_BLAKE2s — C implementation
// Direct translation of noise-zig/{cipher_state,symmetric_state,handshake_state,crypto}.zig

#include "noise.h"
#include "vendor/monocypher.h"
#include "vendor/blake2.h"
#include <string.h>
#include <stdint.h>

// ── Platform RNG ──────────────────────────────────────────────────────────────

#ifdef _WIN32
extern int __stdcall SystemFunction036(void *, unsigned long);
int noise_random(uint8_t *buf, size_t len) {
    return SystemFunction036(buf, (unsigned long)len) ? 0 : -1;
}
#elif defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
int noise_random(uint8_t *buf, size_t len) {
    while (len > 0) {
        long n = syscall(SYS_getrandom, buf, len, 0);
        if (n < 0) return -1;
        buf += n; len -= (size_t)n;
    }
    return 0;
}
#else  // macOS, BSD
#include <stdlib.h>
int noise_random(uint8_t *buf, size_t len) {
    arc4random_buf(buf, len);
    return 0;
}
#endif

// ── Crypto helpers ────────────────────────────────────────────────────────────

static void noise_hash(uint8_t out[32], const void *data, size_t len) {
    blake2s(out, 32, data, len, NULL, 0);
}

static void noise_hmac(uint8_t out[32], const uint8_t *key, size_t key_len,
                       const uint8_t *data, size_t data_len) {
    uint8_t ipad[64], opad[64], k[64];
    memset(k, 0, 64);
    if (key_len > 64) noise_hash(k, key, key_len);
    else              memcpy(k, key, key_len);

    for (int i = 0; i < 64; i++) {
        ipad[i] = k[i] ^ 0x36;
        opad[i] = k[i] ^ 0x5c;
    }

    blake2s_state S;
    uint8_t inner[32];
    blake2s_init(&S, 32);
    blake2s_update(&S, ipad, 64);
    blake2s_update(&S, data, data_len);
    blake2s_final(&S, inner, 32);

    blake2s_init(&S, 32);
    blake2s_update(&S, opad, 64);
    blake2s_update(&S, inner, 32);
    blake2s_final(&S, out, 32);

    crypto_wipe(k, 64);
    crypto_wipe(inner, 32);
}

static void noise_hkdf2(const uint8_t ck[32], const uint8_t *ikm, size_t ikm_len,
                         uint8_t out1[32], uint8_t out2[32]) {
    uint8_t prk[32];
    noise_hmac(prk, ck, 32, ikm, ikm_len);

    uint8_t one = 0x01;
    noise_hmac(out1, prk, 32, &one, 1);

    uint8_t tmp[33];
    memcpy(tmp, out1, 32);
    tmp[32] = 0x02;
    noise_hmac(out2, prk, 32, tmp, 33);

    crypto_wipe(prk, 32);
}

// Returns 0 on success, -1 if DH produced all-zero output (weak/invalid key)
static int noise_dh(uint8_t out[32], const uint8_t secret[32], const uint8_t pub[32]) {
    crypto_x25519(out, secret, pub);
    // Reject all-zero shared secret (low-order point / invalid key)
    uint8_t zero[32] = {0};
    if (crypto_verify32(out, zero) == 0) {
        crypto_wipe(out, 32);
        return -1;
    }
    return 0;
}

// ── CipherState ───────────────────────────────────────────────────────────────

static void cipher_init(noise_cipher_state_t *cs, const uint8_t *key) {
    if (key) {
        memcpy(cs->key, key, 32);
        cs->has_key = 1;
    } else {
        cs->has_key = 0;
    }
    cs->nonce = 0;
}

static void cipher_nonce_bytes(const noise_cipher_state_t *cs, uint8_t nonce[12]) {
    memset(nonce, 0, 12);
    uint64_t n = cs->nonce;
    for (int i = 0; i < 8; i++) {
        nonce[4 + i] = (uint8_t)(n & 0xff);
        n >>= 8;
    }
}

static int cipher_encrypt(noise_cipher_state_t *cs, uint8_t *out, size_t out_cap,
                           const uint8_t *ad, size_t ad_len,
                           const uint8_t *pt, size_t pt_len) {
    if (!cs->has_key) {
        if (out_cap < pt_len) return -1;
        memcpy(out, pt, pt_len);
        return (int)pt_len;
    }
    if (cs->nonce == UINT64_MAX) return -1;  // nonce exhaustion
    if (out_cap < pt_len + NOISE_TAG_LEN) return -1;

    uint8_t nonce[12];
    cipher_nonce_bytes(cs, nonce);

    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, cs->key, nonce);
    crypto_aead_write(&ctx, out, out + pt_len, ad, ad_len, pt, pt_len);
    crypto_wipe(&ctx, sizeof(ctx));
    cs->nonce++;
    return (int)(pt_len + NOISE_TAG_LEN);
}

static int cipher_decrypt(noise_cipher_state_t *cs, uint8_t *out, size_t out_cap,
                           const uint8_t *ad, size_t ad_len,
                           const uint8_t *ct, size_t ct_len) {
    if (!cs->has_key) {
        if (out_cap < ct_len) return -1;
        memcpy(out, ct, ct_len);
        return (int)ct_len;
    }
    if (cs->nonce == UINT64_MAX) return -1;  // nonce exhaustion
    if (ct_len < NOISE_TAG_LEN) return -1;
    size_t pt_len = ct_len - NOISE_TAG_LEN;
    if (out_cap < pt_len) return -1;

    uint8_t nonce[12];
    cipher_nonce_bytes(cs, nonce);

    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, cs->key, nonce);
    if (crypto_aead_read(&ctx, out, ct + pt_len, ad, ad_len, ct, pt_len) != 0) {
        crypto_wipe(&ctx, sizeof(ctx));
        return -1;
    }
    crypto_wipe(&ctx, sizeof(ctx));
    cs->nonce++;
    return (int)pt_len;
}

// ── SymmetricState ────────────────────────────────────────────────────────────

static const char PROTOCOL_NAME[] = "Noise_IK_25519_ChaChaPoly_BLAKE2s";

static void symmetric_init(noise_symmetric_state_t *ss) {
    // protocol_name (34 bytes) > 32, so hash it
    noise_hash(ss->h, PROTOCOL_NAME, sizeof(PROTOCOL_NAME) - 1);
    memcpy(ss->ck, ss->h, 32);
    cipher_init(&ss->cipher, NULL);
}

static void symmetric_mix_hash(noise_symmetric_state_t *ss, const uint8_t *data, size_t len) {
    blake2s_state S;
    blake2s_init(&S, 32);
    blake2s_update(&S, ss->h, 32);
    blake2s_update(&S, data, len);
    blake2s_final(&S, ss->h, 32);
}

static void symmetric_mix_key(noise_symmetric_state_t *ss, const uint8_t *ikm, size_t ikm_len) {
    uint8_t out1[32], out2[32];
    noise_hkdf2(ss->ck, ikm, ikm_len, out1, out2);
    memcpy(ss->ck, out1, 32);
    cipher_init(&ss->cipher, out2);
    crypto_wipe(out1, 32);
    crypto_wipe(out2, 32);
}

static int symmetric_encrypt_and_hash(noise_symmetric_state_t *ss,
                                       uint8_t *out, size_t out_cap,
                                       const uint8_t *pt, size_t pt_len) {
    int ct_len = cipher_encrypt(&ss->cipher, out, out_cap, ss->h, 32, pt, pt_len);
    if (ct_len < 0) return -1;
    symmetric_mix_hash(ss, out, (size_t)ct_len);
    return ct_len;
}

static int symmetric_decrypt_and_hash(noise_symmetric_state_t *ss,
                                       uint8_t *out, size_t out_cap,
                                       const uint8_t *ct, size_t ct_len) {
    int pt_len = cipher_decrypt(&ss->cipher, out, out_cap, ss->h, 32, ct, ct_len);
    if (pt_len < 0) return -1;
    symmetric_mix_hash(ss, ct, ct_len);
    return pt_len;
}

static void symmetric_split(const noise_symmetric_state_t *ss,
                             noise_cipher_state_t *initiator,
                             noise_cipher_state_t *responder) {
    uint8_t out1[32], out2[32];
    noise_hkdf2(ss->ck, (const uint8_t *)"", 0, out1, out2);
    cipher_init(initiator, out1);
    cipher_init(responder, out2);
    crypto_wipe(out1, 32);
    crypto_wipe(out2, 32);
}

// ── HandshakeState (IK initiator only) ────────────────────────────────────────

void noise_keypair_from_secret(noise_keypair_t *kp, const uint8_t secret[32]) {
    memcpy(kp->secret_key, secret, 32);
    crypto_x25519_public_key(kp->public_key, secret);
}

int noise_handshake_init(noise_handshake_t *hs,
                         const noise_keypair_t *local_static,
                         const uint8_t remote_static_pub[32]) {
    memset(hs, 0, sizeof(*hs));
    memcpy(&hs->s, local_static, sizeof(noise_keypair_t));
    memcpy(hs->rs, remote_static_pub, 32);

    symmetric_init(&hs->symmetric);
    // IK pre-messages: pre_r = [s] → mixHash(rs)
    symmetric_mix_hash(&hs->symmetric, hs->rs, 32);
    return 0;
}

// IK message 0 (initiator → responder): tokens = [e, es, s, ss]
int noise_handshake_write(noise_handshake_t *hs,
                          const uint8_t *payload, size_t payload_len,
                          uint8_t *out, size_t out_cap) {
    if (hs->complete || hs->message_index != 0) return -1;
    size_t used = 0;

    // Token: e — generate ephemeral, write pubkey
    if (noise_random(hs->e.secret_key, 32) < 0) return -1;
    crypto_x25519_public_key(hs->e.public_key, hs->e.secret_key);
    if (out_cap - used < 32) return -1;
    memcpy(out + used, hs->e.public_key, 32);
    symmetric_mix_hash(&hs->symmetric, hs->e.public_key, 32);
    used += 32;

    // Token: es — DH(e, rs)
    uint8_t dh_result[32];
    if (noise_dh(dh_result, hs->e.secret_key, hs->rs) < 0) return -1;
    symmetric_mix_key(&hs->symmetric, dh_result, 32);

    // Token: s — encrypt and send static pubkey
    int ct_len = symmetric_encrypt_and_hash(&hs->symmetric, out + used, out_cap - used,
                                             hs->s.public_key, 32);
    if (ct_len < 0) return -1;
    used += (size_t)ct_len;

    // Token: ss — DH(s, rs)
    if (noise_dh(dh_result, hs->s.secret_key, hs->rs) < 0) return -1;
    symmetric_mix_key(&hs->symmetric, dh_result, 32);
    crypto_wipe(dh_result, 32);

    // Encrypt payload
    ct_len = symmetric_encrypt_and_hash(&hs->symmetric, out + used, out_cap - used,
                                         payload, payload_len);
    if (ct_len < 0) return -1;
    used += (size_t)ct_len;

    hs->message_index = 1;
    return (int)used;
}

// IK message 1 (responder → initiator): tokens = [e, ee, se]
int noise_handshake_read(noise_handshake_t *hs,
                         const uint8_t *msg, size_t msg_len,
                         uint8_t *out, size_t out_cap) {
    if (hs->complete || hs->message_index != 1) return -1;
    size_t off = 0;

    // Token: e — read remote ephemeral
    if (msg_len - off < 32) return -1;
    memcpy(hs->re, msg + off, 32);
    symmetric_mix_hash(&hs->symmetric, hs->re, 32);
    off += 32;

    // Token: ee — DH(e, re)
    uint8_t dh_result[32];
    if (noise_dh(dh_result, hs->e.secret_key, hs->re) < 0) return -1;
    symmetric_mix_key(&hs->symmetric, dh_result, 32);

    // Token: se — DH(s, re) (initiator: static secret, remote ephemeral)
    if (noise_dh(dh_result, hs->s.secret_key, hs->re) < 0) return -1;
    symmetric_mix_key(&hs->symmetric, dh_result, 32);
    crypto_wipe(dh_result, 32);

    // Decrypt payload
    int pt_len = symmetric_decrypt_and_hash(&hs->symmetric, out, out_cap,
                                             msg + off, msg_len - off);
    if (pt_len < 0) return -1;

    hs->message_index = 2;
    hs->complete = 1;
    return pt_len;
}

int noise_handshake_split(const noise_handshake_t *hs, noise_transport_t *transport) {
    if (!hs->complete) return -1;
    noise_cipher_state_t initiator, responder;
    symmetric_split(&hs->symmetric, &initiator, &responder);
    transport->send = initiator;
    transport->recv = responder;
    return 0;
}

int noise_transport_write(noise_transport_t *t,
                          uint8_t *out, size_t out_cap,
                          const uint8_t *plaintext, size_t pt_len) {
    return cipher_encrypt(&t->send, out, out_cap, (const uint8_t *)"", 0, plaintext, pt_len);
}

int noise_transport_read(noise_transport_t *t,
                         uint8_t *out, size_t out_cap,
                         const uint8_t *ciphertext, size_t ct_len) {
    return cipher_decrypt(&t->recv, out, out_cap, (const uint8_t *)"", 0, ciphertext, ct_len);
}
