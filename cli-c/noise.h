// Noise_IK_25519_ChaChaPoly_BLAKE2s — C implementation
// Direct translation of noise-zig/{cipher_state,symmetric_state,handshake_state,crypto}.zig

#ifndef NOISE_H
#define NOISE_H

#include <stdint.h>
#include <stddef.h>

#define NOISE_TAG_LEN 16

typedef struct {
    uint8_t public_key[32];
    uint8_t secret_key[32];
} noise_keypair_t;

typedef struct {
    uint8_t key[32];
    int     has_key;
    uint64_t nonce;
} noise_cipher_state_t;

typedef struct {
    uint8_t ck[32];
    uint8_t h[32];
    noise_cipher_state_t cipher;
} noise_symmetric_state_t;

typedef struct {
    noise_cipher_state_t send;
    noise_cipher_state_t recv;
} noise_transport_t;

typedef struct {
    noise_symmetric_state_t symmetric;
    noise_keypair_t  s;          // local static
    uint8_t          rs[32];     // remote static public
    noise_keypair_t  e;          // local ephemeral
    uint8_t          re[32];     // remote ephemeral public
    int              message_index;
    int              complete;
} noise_handshake_t;

// Initialize IK handshake as initiator
int noise_handshake_init(noise_handshake_t *hs,
                         const noise_keypair_t *local_static,
                         const uint8_t remote_static_pub[32]);

// Write handshake message, returns bytes written to out, or -1 on error
int noise_handshake_write(noise_handshake_t *hs,
                          const uint8_t *payload, size_t payload_len,
                          uint8_t *out, size_t out_cap);

// Read handshake message, returns payload bytes written to out, or -1 on error
int noise_handshake_read(noise_handshake_t *hs,
                         const uint8_t *msg, size_t msg_len,
                         uint8_t *out, size_t out_cap);

// Split into transport state after handshake complete
int noise_handshake_split(const noise_handshake_t *hs, noise_transport_t *transport);

// Encrypt a transport message, returns bytes written or -1
int noise_transport_write(noise_transport_t *t,
                          uint8_t *out, size_t out_cap,
                          const uint8_t *plaintext, size_t pt_len);

// Decrypt a transport message, returns plaintext bytes or -1
int noise_transport_read(noise_transport_t *t,
                         uint8_t *out, size_t out_cap,
                         const uint8_t *ciphertext, size_t ct_len);

// Generate keypair from secret key (derive public via X25519)
void noise_keypair_from_secret(noise_keypair_t *kp, const uint8_t secret[32]);

// Platform-native secure random. Returns 0 on success, -1 on failure.
int noise_random(uint8_t *buf, size_t len);

#endif
