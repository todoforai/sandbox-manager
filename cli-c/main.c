/// sandbox CLI — manages Firecracker VMs via Noise_IK TCP to sandbox-manager
///
/// Config (env):
///   NOISE_ADDR              host:port of sandbox-manager Noise server (default: 127.0.0.1:9001)
///   NOISE_LOCAL_PRIVATE_KEY 32-byte hex — CLI private key
///   NOISE_REMOTE_PUBLIC_KEY 32-byte hex — sandbox-manager public key
///
/// Usage:
///   sandbox health
///   sandbox stats
///   sandbox create --user <id> [--template alpine-base] [--size medium] [--token <api-key>]
///   sandbox list [--user <id>]
///   sandbox get <id>
///   sandbox delete <id>
///   sandbox pause <id>
///   sandbox resume <id>
///   sandbox template list
///   sandbox template create <name> --kernel <path> --rootfs <path> [--boot-args <args>] [--description <text>] [--package <name> ...]

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "noise.h"
#include "vendor/monocypher.h"

// ── Platform socket abstraction ───────────────────────────────────────────────

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET sock_t;
#define SOCK_INVALID INVALID_SOCKET
static void sock_init(void) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        fprintf(stderr, "error: WSAStartup failed\n");
        exit(1);
    }
}
static void sock_close(sock_t s) { closesocket(s); }
#else
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
typedef int sock_t;
#define SOCK_INVALID (-1)
#define sock_init() ((void)0)
static void sock_close(sock_t s) { close(s); }
#endif

#define MAX_FRAME (1024 * 1024)

// ── Helpers ───────────────────────────────────────────────────────────────────

static void fatal(const char *msg) {
    fprintf(stderr, "error: %s\n", msg);
    exit(1);
}

static const char *flag_value(int argc, char **argv, int start, const char *flag) {
    for (int i = start; i < argc - 1; i++)
        if (strcmp(argv[i], flag) == 0) return argv[i + 1];
    return NULL;
}

static int flag_count(int argc, char **argv, int start, const char *flag) {
    int count = 0;
    for (int i = start; i < argc; i++)
        if (strcmp(argv[i], flag) == 0) count++;
    return count;
}

static int hex_decode(uint8_t *out, size_t out_len, const char *hex) {
    size_t hex_len = strlen(hex);
    if (hex_len != out_len * 2) return -1;
    for (size_t i = 0; i < out_len; i++) {
        unsigned int byte;
        if (sscanf(hex + i * 2, "%2x", &byte) != 1) return -1;
        out[i] = (uint8_t)byte;
    }
    return 0;
}

static void hex_encode(char *out, const uint8_t *data, size_t len) {
    for (size_t i = 0; i < len; i++)
        sprintf(out + i * 2, "%02x", data[i]);
}

// ── JSON builder (minimal, for known shapes) ─────────────────────────────────

typedef struct {
    char *buf;
    size_t len, cap;
    int overflow;
} json_buf_t;

static void jb_init(json_buf_t *jb, char *buf, size_t cap) {
    jb->buf = buf; jb->len = 0; jb->cap = cap; jb->overflow = 0;
}

static void jb_raw(json_buf_t *jb, const char *s) {
    size_t n = strlen(s);
    if (jb->len + n >= jb->cap) { jb->overflow = 1; return; }
    memcpy(jb->buf + jb->len, s, n);
    jb->len += n;
}

static void jb_char(json_buf_t *jb, char c) {
    if (jb->len + 1 >= jb->cap) { jb->overflow = 1; return; }
    jb->buf[jb->len++] = c;
}

// Write a JSON-escaped string value (handles \, ", control chars)
static void jb_escaped(json_buf_t *jb, const char *s) {
    jb_char(jb, '"');
    for (; *s; s++) {
        switch (*s) {
        case '"':  jb_raw(jb, "\\\""); break;
        case '\\': jb_raw(jb, "\\\\"); break;
        case '\n': jb_raw(jb, "\\n");  break;
        case '\r': jb_raw(jb, "\\r");  break;
        case '\t': jb_raw(jb, "\\t");  break;
        default:
            if ((unsigned char)*s < 0x20) {
                char esc[7];
                snprintf(esc, sizeof(esc), "\\u%04x", (unsigned char)*s);
                jb_raw(jb, esc);
            } else {
                jb_char(jb, *s);
            }
        }
    }
    jb_char(jb, '"');
}

// Write "key":"value", — skips if val is NULL
static void jb_str(json_buf_t *jb, const char *key, const char *val) {
    if (!val) return;
    jb_escaped(jb, key);
    jb_char(jb, ':');
    jb_escaped(jb, val);
    jb_char(jb, ',');
}

static void jb_obj_open(json_buf_t *jb)  { jb_char(jb, '{'); }
static void jb_obj_close(json_buf_t *jb) {
    if (jb->len > 0 && jb->buf[jb->len - 1] == ',') jb->len--;
    jb_char(jb, '}');
}

// ── TCP framing ───────────────────────────────────────────────────────────────

static int sock_recv_exact(sock_t fd, uint8_t *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        int n = recv(fd, (char *)buf + done, (int)(len - done), 0);
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static int sock_send_all(sock_t fd, const uint8_t *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        int n = send(fd, (const char *)buf + done, (int)(len - done), 0);
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static int write_frame(sock_t fd, const uint8_t *data, size_t len) {
    uint8_t hdr[4] = {
        (uint8_t)(len >> 24), (uint8_t)(len >> 16),
        (uint8_t)(len >> 8),  (uint8_t)len
    };
    if (sock_send_all(fd, hdr, 4) < 0) return -1;
    return sock_send_all(fd, data, len);
}

static int read_frame(sock_t fd, uint8_t **out, size_t *out_len) {
    uint8_t hdr[4];
    if (sock_recv_exact(fd, hdr, 4) < 0) return -1;
    uint32_t len = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                   ((uint32_t)hdr[2] << 8) | (uint32_t)hdr[3];
    if (len == 0 || len > MAX_FRAME) return -1;
    *out = malloc(len);
    if (!*out) return -1;
    if (sock_recv_exact(fd, *out, len) < 0) { free(*out); return -1; }
    *out_len = len;
    return 0;
}

// ── TCP connect ───────────────────────────────────────────────────────────────

static sock_t tcp_connect(const char *host, const char *port) {
    struct addrinfo hints = {0}, *res, *rp;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0) return SOCK_INVALID;
    sock_t fd = SOCK_INVALID;
    for (rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd == SOCK_INVALID) continue;
        if (connect(fd, rp->ai_addr, (int)rp->ai_addrlen) == 0) break;
        sock_close(fd);
        fd = SOCK_INVALID;
    }
    freeaddrinfo(res);
    return fd;
}

// ── Response handling ─────────────────────────────────────────────────────────

static void print_response(const uint8_t *resp, size_t len) {
    fwrite(resp, 1, len, stdout);
    if (len == 0 || resp[len - 1] != '\n') putchar('\n');
}

// ── Core: connect, handshake, send, receive ───────────────────────────────────

static void run_cmd(const char *json_request, size_t req_len) {
    sock_init();

    // Load keys
    const char *priv_hex = getenv("NOISE_LOCAL_PRIVATE_KEY");
    if (!priv_hex) fatal("NOISE_LOCAL_PRIVATE_KEY not set");
    const char *pub_hex = getenv("NOISE_REMOTE_PUBLIC_KEY");
    if (!pub_hex) fatal("NOISE_REMOTE_PUBLIC_KEY not set");

    uint8_t secret[32], remote_pub[32];
    if (hex_decode(secret, 32, priv_hex) < 0) fatal("NOISE_LOCAL_PRIVATE_KEY: invalid hex");
    if (hex_decode(remote_pub, 32, pub_hex) < 0) fatal("NOISE_REMOTE_PUBLIC_KEY: invalid hex");

    noise_keypair_t local_kp;
    noise_keypair_from_secret(&local_kp, secret);
    crypto_wipe(secret, 32);

    // Resolve address
    const char *addr_str = getenv("NOISE_ADDR");
    if (!addr_str) addr_str = "127.0.0.1:9001";
    char host[256], port_str[16];
    const char *colon = strrchr(addr_str, ':');
    if (!colon) fatal("NOISE_ADDR: missing port");
    size_t hlen = (size_t)(colon - addr_str);
    if (hlen >= sizeof(host)) fatal("NOISE_ADDR: host too long");
    memcpy(host, addr_str, hlen);
    host[hlen] = '\0';
    snprintf(port_str, sizeof(port_str), "%s", colon + 1);

    // Connect
    sock_t fd = tcp_connect(host, port_str);
    if (fd == SOCK_INVALID) fatal("connect failed");

    // Handshake
    noise_handshake_t hs;
    noise_handshake_init(&hs, &local_kp, remote_pub);

    uint8_t m1_buf[256];
    int m1_len = noise_handshake_write(&hs, (const uint8_t *)"", 0, m1_buf, sizeof(m1_buf));
    if (m1_len < 0) fatal("handshake write failed");
    if (write_frame(fd, m1_buf, (size_t)m1_len) < 0) fatal("send handshake failed");

    uint8_t *m2_data;
    size_t m2_len;
    if (read_frame(fd, &m2_data, &m2_len) < 0) fatal("recv handshake failed");
    uint8_t p2_buf[64];
    if (noise_handshake_read(&hs, m2_data, m2_len, p2_buf, sizeof(p2_buf)) < 0) {
        free(m2_data);
        fatal("handshake read failed");
    }
    free(m2_data);

    noise_transport_t transport;
    if (noise_handshake_split(&hs, &transport) < 0) fatal("handshake split failed");

    // Encrypt and send request
    uint8_t *enc_buf = malloc(req_len + 64);
    if (!enc_buf) fatal("malloc");
    int enc_len = noise_transport_write(&transport, enc_buf, req_len + 64,
                                         (const uint8_t *)json_request, req_len);
    if (enc_len < 0) { free(enc_buf); fatal("encrypt failed"); }
    if (write_frame(fd, enc_buf, (size_t)enc_len) < 0) { free(enc_buf); fatal("send failed"); }
    free(enc_buf);

    // Read and decrypt response
    uint8_t *resp_enc;
    size_t resp_enc_len;
    if (read_frame(fd, &resp_enc, &resp_enc_len) < 0) fatal("recv failed");
    uint8_t *resp_dec = malloc(resp_enc_len);
    if (!resp_dec) { free(resp_enc); fatal("malloc"); }
    int resp_len = noise_transport_read(&transport, resp_dec, resp_enc_len,
                                         resp_enc, resp_enc_len);
    free(resp_enc);
    if (resp_len < 0) { free(resp_dec); fatal("decrypt failed"); }

    sock_close(fd);
    print_response(resp_dec, (size_t)resp_len);
    free(resp_dec);
}

// ── Build JSON request and dispatch ───────────────────────────────────────────

static void build_and_run(const char *type, const char *payload_json) {
    uint8_t id_bytes[4];
    if (noise_random(id_bytes, 4) < 0) fatal("RNG failed");
    char id_hex[9];
    hex_encode(id_hex, id_bytes, 4);
    id_hex[8] = '\0';

    char req[4096];
    json_buf_t jb;
    jb_init(&jb, req, sizeof(req));
    jb_obj_open(&jb);
    jb_str(&jb, "id", id_hex);
    jb_str(&jb, "type", type);
    if (payload_json && payload_json[0]) {
        jb_raw(&jb, "\"payload\":");
        jb_raw(&jb, payload_json);
    } else {
        jb_raw(&jb, "\"payload\":{}");
    }
    jb_obj_close(&jb);
    if (jb.overflow) fatal("request too large");
    jb.buf[jb.len] = '\0';

    run_cmd(req, jb.len);
}

static void jb_str_array_from_flag(json_buf_t *jb, const char *key, int argc, char **argv, int start, const char *flag) {
    int first = 1;
    if (flag_count(argc, argv, start, flag) == 0) return;
    jb_escaped(jb, key);
    jb_char(jb, ':');
    jb_char(jb, '[');
    for (int i = start; i < argc - 1; i++) {
        if (strcmp(argv[i], flag) != 0) continue;
        if (!first) jb_char(jb, ',');
        jb_escaped(jb, argv[i + 1]);
        first = 0;
    }
    jb_char(jb, ']');
    jb_char(jb, ',');
}

static void build_payload_and_run(const char *type, int argc, char **argv, int start) {
    char payload[2048];
    json_buf_t jb;
    jb_init(&jb, payload, sizeof(payload));
    jb_obj_open(&jb);

    if (strcmp(type, "sandbox.list") == 0) {
        jb_str(&jb, "user_id", flag_value(argc, argv, start, "--user"));
    } else if (strcmp(type, "sandbox.get") == 0 || strcmp(type, "sandbox.delete") == 0 ||
               strcmp(type, "sandbox.pause") == 0 || strcmp(type, "sandbox.resume") == 0) {
        if (start < argc) jb_str(&jb, "id", argv[start]);
    } else if (strcmp(type, "sandbox.create") == 0) {
        jb_str(&jb, "user_id", flag_value(argc, argv, start, "--user"));
        jb_str(&jb, "template", flag_value(argc, argv, start, "--template"));
        jb_str(&jb, "size", flag_value(argc, argv, start, "--size"));
        jb_str(&jb, "edge_token", flag_value(argc, argv, start, "--token"));
    } else if (strcmp(type, "template.create") == 0) {
        if (start < argc && argv[start][0] != '-')
            jb_str(&jb, "name", argv[start]);
        jb_str(&jb, "kernel_path", flag_value(argc, argv, start, "--kernel"));
        jb_str(&jb, "rootfs_path", flag_value(argc, argv, start, "--rootfs"));
        jb_str(&jb, "boot_args", flag_value(argc, argv, start, "--boot-args"));
        jb_str(&jb, "description", flag_value(argc, argv, start, "--description"));
        jb_str_array_from_flag(&jb, "packages", argc, argv, start, "--package");
    }

    jb_obj_close(&jb);
    if (jb.overflow) fatal("payload too large");
    payload[jb.len] = '\0';

    build_and_run(type, payload);
}

// ── Usage ─────────────────────────────────────────────────────────────────────

static void usage(void) {
    fprintf(stderr,
        "Usage: sandbox <command> [options]\n"
        "\n"
        "Commands:\n"
        "  health                          Health check\n"
        "  stats                           VM statistics\n"
        "  create --user <id> [opts]       Create sandbox VM\n"
        "    --template <name>             Template (default: alpine-base)\n"
        "    --size <small|medium|large|xlarge>\n"
        "    --token <api-key>             Auth token\n"
        "  list [--user <id>]              List sandboxes\n"
        "  get <id>                        Get sandbox details\n"
        "  delete <id>                     Delete sandbox\n"
        "  pause <id>                      Pause sandbox\n"
        "  resume <id>                     Resume sandbox\n"
        "  template list                   List templates\n"
        "  template create <name> --kernel <path> --rootfs <path>\n"
        "    [--boot-args <args>]         Custom kernel boot arguments\n"
        "    [--description <text>]       Template description metadata\n"
        "    [--package <name> ...]       Template package metadata (repeatable)\n"
        "\n"
        "Env:\n"
        "  NOISE_ADDR              sandbox-manager Noise address (default: 127.0.0.1:9001)\n"
        "  NOISE_LOCAL_PRIVATE_KEY 32-byte hex private key\n"
        "  NOISE_REMOTE_PUBLIC_KEY 32-byte hex server public key\n"
    );
    exit(1);
}

static void usage_cmd(const char *hint) {
    fprintf(stderr, "error: Usage: sandbox %s\n", hint);
    exit(1);
}

// ── Main ──────────────────────────────────────────────────────────────────────

int main(int argc, char **argv) {
    if (argc < 2) usage();
    const char *cmd = argv[1];

    if (strcmp(cmd, "health") == 0) {
        build_and_run("health.get", NULL);
    } else if (strcmp(cmd, "stats") == 0) {
        build_and_run("stats.get", NULL);
    } else if (strcmp(cmd, "list") == 0) {
        build_payload_and_run("sandbox.list", argc, argv, 2);
    } else if (strcmp(cmd, "get") == 0) {
        if (argc < 3) usage_cmd("get <id>");
        build_payload_and_run("sandbox.get", argc, argv, 2);
    } else if (strcmp(cmd, "delete") == 0) {
        if (argc < 3) usage_cmd("delete <id>");
        build_payload_and_run("sandbox.delete", argc, argv, 2);
    } else if (strcmp(cmd, "pause") == 0) {
        if (argc < 3) usage_cmd("pause <id>");
        build_payload_and_run("sandbox.pause", argc, argv, 2);
    } else if (strcmp(cmd, "resume") == 0) {
        if (argc < 3) usage_cmd("resume <id>");
        build_payload_and_run("sandbox.resume", argc, argv, 2);
    } else if (strcmp(cmd, "create") == 0) {
        if (!flag_value(argc, argv, 2, "--user"))
            usage_cmd("create --user <id>");
        build_payload_and_run("sandbox.create", argc, argv, 2);
    } else if (strcmp(cmd, "template") == 0) {
        if (argc < 3) usage_cmd("template <list|create>");
        if (strcmp(argv[2], "list") == 0) {
            build_and_run("templates.list", NULL);
        } else if (strcmp(argv[2], "create") == 0) {
            if (argc < 4 || argv[3][0] == '-')
                usage_cmd("template create <name> --kernel <path> --rootfs <path> [--boot-args <args>] [--description <text>] [--package <name> ...]");
            if (!flag_value(argc, argv, 3, "--kernel") || !flag_value(argc, argv, 3, "--rootfs"))
                usage_cmd("template create <name> --kernel <path> --rootfs <path> [--boot-args <args>] [--description <text>] [--package <name> ...]");
            build_payload_and_run("template.create", argc, argv, 3);
        } else {
            usage_cmd("template <list|create>");
        }
    } else {
        usage();
    }
    return 0;
}
