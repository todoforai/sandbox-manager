/// sandbox CLI — manages Firecracker VMs via Noise_NX TCP to sandbox-manager
///
/// Config (env):
///   NOISE_ADDR              host:port of sandbox-manager Noise server (default: 127.0.0.1:9001)
///   NOISE_REMOTE_PUBLIC_KEY 32-byte hex — sandbox-manager public key
///
/// Or run `sandbox login` to authenticate via browser and save credentials.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "noise.h"
#include "args.h"

#define LOGIN_IMPLEMENTATION
#include "login.h"

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
#define MAX_PACKAGES 64

// ── Helpers ───────────────────────────────────────────────────────────────────

static void fatal(const char *msg) {
    fprintf(stderr, "error: %s\n", msg);
    exit(1);
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
    for (size_t i = 0; i < len; i++) sprintf(out + i * 2, "%02x", data[i]);
}

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

static void jb_escaped(json_buf_t *jb, const char *s) {
    jb_char(jb, '"');
    for (; *s; s++) {
        switch (*s) {
        case '"':  jb_raw(jb, "\\\""); break;
        case '\\': jb_raw(jb, "\\\\"); break;
        case '\n': jb_raw(jb, "\\n"); break;
        case '\r': jb_raw(jb, "\\r"); break;
        case '\t': jb_raw(jb, "\\t"); break;
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

static void jb_str(json_buf_t *jb, const char *key, const char *val) {
    if (!val) return;
    jb_escaped(jb, key);
    jb_char(jb, ':');
    jb_escaped(jb, val);
    jb_char(jb, ',');
}

static void jb_obj_open(json_buf_t *jb) { jb_char(jb, '{'); }
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

    const char *pub_hex = getenv("NOISE_REMOTE_PUBLIC_KEY");
    const char *addr_str = getenv("NOISE_ADDR");

    // Fall back to saved credentials from `sandbox login`
    login_credentials_t saved_creds;
    if ((!pub_hex || !addr_str) && login_load_credentials(&saved_creds) == 0) {
        if (!pub_hex && saved_creds.sandbox_manager_noise_public_key[0])
            pub_hex = saved_creds.sandbox_manager_noise_public_key;
        if (!addr_str && saved_creds.sandbox_manager_noise_addr[0])
            addr_str = saved_creds.sandbox_manager_noise_addr;
    }

    if (!pub_hex) fatal("NOISE_REMOTE_PUBLIC_KEY not set (run `sandbox login` or set env)");

    uint8_t remote_pub[32];
    if (hex_decode(remote_pub, 32, pub_hex) < 0) fatal("NOISE_REMOTE_PUBLIC_KEY: invalid hex");

    if (!addr_str) addr_str = "127.0.0.1:9001";
    char host[256], port_str[16];
    const char *colon = strrchr(addr_str, ':');
    if (!colon) fatal("NOISE_ADDR: missing port");
    size_t hlen = (size_t)(colon - addr_str);
    if (hlen >= sizeof(host)) fatal("NOISE_ADDR: host too long");
    memcpy(host, addr_str, hlen);
    host[hlen] = '\0';
    snprintf(port_str, sizeof(port_str), "%s", colon + 1);

    sock_t fd = tcp_connect(host, port_str);
    if (fd == SOCK_INVALID) fatal("connect failed");

    noise_handshake_t hs;
    noise_handshake_init(&hs, remote_pub);

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

    uint8_t *enc_buf = malloc(req_len + 64);
    if (!enc_buf) fatal("malloc");
    int enc_len = noise_transport_write(&transport, enc_buf, req_len + 64,
        (const uint8_t *)json_request, req_len);
    if (enc_len < 0) { free(enc_buf); fatal("encrypt failed"); }
    if (write_frame(fd, enc_buf, (size_t)enc_len) < 0) { free(enc_buf); fatal("send failed"); }
    free(enc_buf);

    uint8_t *resp_enc;
    size_t resp_enc_len;
    if (read_frame(fd, &resp_enc, &resp_enc_len) < 0) fatal("recv failed");
    uint8_t *resp_dec = malloc(resp_enc_len);
    if (!resp_dec) { free(resp_enc); fatal("malloc"); }
    int resp_len = noise_transport_read(&transport, resp_dec, resp_enc_len, resp_enc, resp_enc_len);
    free(resp_enc);
    if (resp_len < 0) { free(resp_dec); fatal("decrypt failed"); }

    sock_close(fd);
    print_response(resp_dec, (size_t)resp_len);
    free(resp_dec);
}

// ── Request builders ──────────────────────────────────────────────────────────

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
    jb_escaped(&jb, "payload");
    jb_char(&jb, ':');
    jb_raw(&jb, payload_json && payload_json[0] ? payload_json : "{}");
    jb_obj_close(&jb);
    if (jb.overflow) fatal("request too large");
    jb.buf[jb.len] = '\0';

    run_cmd(req, jb.len);
}

static void build_empty_payload(char *payload, size_t size) {
    json_buf_t jb;
    jb_init(&jb, payload, size);
    jb_obj_open(&jb);
    jb_obj_close(&jb);
    if (jb.overflow) fatal("payload too large");
    payload[jb.len] = '\0';
}

static void build_id_payload(char *payload, size_t size, const char *id) {
    json_buf_t jb;
    jb_init(&jb, payload, size);
    jb_obj_open(&jb);
    jb_str(&jb, "id", id);
    jb_obj_close(&jb);
    if (jb.overflow) fatal("payload too large");
    payload[jb.len] = '\0';
}

// ── Usage ─────────────────────────────────────────────────────────────────────

static void cmd_login(int argc, char **argv) {
    ketopt_t opt = KETOPT_INIT;
    ko_longopt_t longopts[] = {{ "help", ko_no_argument, 'h' }, { 0, 0, 0 }};
    int c;
    while ((c = ketopt(&opt, argc, argv, 1, "h", longopts)) >= 0) {
        if (c == 'h') { cli_usage(stdout, "sandbox", "login"); exit(0); }
        cli_parse_error("sandbox", "login", argc, argv, &opt, c);
    }

    const char *addr = getenv("NOISE_BACKEND_ADDR");
    const char *pub  = getenv("NOISE_BACKEND_PUBLIC_KEY");
    if (!addr) addr = "api.todofor.ai:4100";
    if (!pub)  pub  = "88e38a377ee697b448ec2779b625049110e05f77587a135df45994062b6bb76a";

    if (login_device_flow(addr, pub, "sandbox") != 0) exit(1);
}

static void usage(void) {
    fprintf(stdout,
        "Usage: sandbox <command> [options]\n"
        "\n"
        "Commands:\n"
        "  login\n"
        "  health\n"
        "  stats\n"
        "  create --user <id> [--template <name>] [--size <size>] [--token <api-key>]\n"
        "  list [--user <id>]\n"
        "  get <id>\n"
        "  delete <id>\n"
        "  pause <id>\n"
        "  resume <id>\n"
        "  template list\n"
        "  template create <name> --kernel <path> --rootfs <path> [--boot-args <args>] [--description <text>] [--package <name> ...]\n"
        "\n"
        "Global options:\n"
        "  -h, --help  Show help\n"
        "\n"
        "Env:\n"
        "  NOISE_ADDR              sandbox-manager Noise address (default: 127.0.0.1:9001)\n"
        "  NOISE_REMOTE_PUBLIC_KEY 32-byte hex server public key\n");
}

static void usage_health(void) { cli_usage(stdout, "sandbox", "health"); }
static void usage_stats(void) { cli_usage(stdout, "sandbox", "stats"); }
static void usage_list(void) { cli_usage(stdout, "sandbox", "list [--user <id>]"); }
static void usage_id(const char *cmd) {
    char usage_buf[64];
    snprintf(usage_buf, sizeof(usage_buf), "%s <id>", cmd);
    cli_usage(stdout, "sandbox", usage_buf);
}
static void usage_create(void) {
    cli_usage(stdout, "sandbox", "create --user <id> [--template <name>] [--size <small|medium|large|xlarge>] [--token <api-key>]");
}
static void usage_template_list(void) { cli_usage(stdout, "sandbox", "template list"); }
static void usage_template_create(void) {
    cli_usage(stdout, "sandbox", "template create <name> --kernel <path> --rootfs <path> [--boot-args <args>] [--description <text>] [--package <name> ...]");
}

static void parse_no_args(const char *usage_str, void (*help_fn)(void), int argc, char **argv) {
    ketopt_t opt = KETOPT_INIT;
    ko_longopt_t longopts[] = {{ "help", ko_no_argument, 'h' }, { 0, 0, 0 }};
    int c;
    while ((c = ketopt(&opt, argc, argv, 1, "h", longopts)) >= 0) {
        if (c == 'h') {
            help_fn();
            exit(0);
        }
        cli_parse_error("sandbox", usage_str, argc, argv, &opt, c);
    }
    if (opt.ind != argc) cli_usage_error("sandbox", usage_str, "unexpected argument");
}

static const char *parse_id_cmd(const char *cmd, int argc, char **argv) {
    char usage_buf[64];
    ketopt_t opt = KETOPT_INIT;
    ko_longopt_t longopts[] = {{ "help", ko_no_argument, 'h' }, { 0, 0, 0 }};
    int c;
    snprintf(usage_buf, sizeof(usage_buf), "%s <id>", cmd);
    while ((c = ketopt(&opt, argc, argv, 1, "h", longopts)) >= 0) {
        if (c == 'h') {
            usage_id(cmd);
            exit(0);
        }
        cli_parse_error("sandbox", usage_buf, argc, argv, &opt, c);
    }
    if (opt.ind >= argc) cli_usage_error("sandbox", usage_buf, "missing <id>");
    if (opt.ind + 1 != argc) cli_usage_error("sandbox", usage_buf, "unexpected argument");
    return argv[opt.ind];
}

static void cmd_health(int argc, char **argv) {
    parse_no_args("health", usage_health, argc, argv);
    build_and_run("health.get", NULL);
}

static void cmd_stats(int argc, char **argv) {
    parse_no_args("stats", usage_stats, argc, argv);
    build_and_run("stats.get", NULL);
}

static void cmd_list(int argc, char **argv) {
    const char *user = NULL;
    ketopt_t opt = KETOPT_INIT;
    ko_longopt_t longopts[] = {
        { "help", ko_no_argument, 'h' },
        { "user", ko_required_argument, 'u' },
        { 0, 0, 0 }
    };
    int c;
    while ((c = ketopt(&opt, argc, argv, 1, "hu:", longopts)) >= 0) {
        if (c == 'h') { usage_list(); exit(0); }
        if (c == 'u') { user = opt.arg; continue; }
        cli_parse_error("sandbox", "list [--user <id>]", argc, argv, &opt, c);
    }
    if (opt.ind != argc) cli_usage_error("sandbox", "list [--user <id>]", "unexpected argument");

    char payload[256];
    json_buf_t jb;
    jb_init(&jb, payload, sizeof(payload));
    jb_obj_open(&jb);
    jb_str(&jb, "user_id", user);
    jb_obj_close(&jb);
    if (jb.overflow) fatal("payload too large");
    payload[jb.len] = '\0';
    build_and_run("sandbox.list", payload);
}

static void cmd_id_request(const char *cmd, const char *type, int argc, char **argv) {
    const char *id = parse_id_cmd(cmd, argc, argv);
    char payload[256];
    build_id_payload(payload, sizeof(payload), id);
    build_and_run(type, payload);
}

static void cmd_create(int argc, char **argv) {
    const char *user = NULL, *template_name = NULL, *size = NULL, *token = NULL;
    ketopt_t opt = KETOPT_INIT;
    ko_longopt_t longopts[] = {
        { "help", ko_no_argument, 'h' },
        { "user", ko_required_argument, 'u' },
        { "template", ko_required_argument, 't' },
        { "size", ko_required_argument, 's' },
        { "token", ko_required_argument, 'k' },
        { 0, 0, 0 }
    };
    int c;
    while ((c = ketopt(&opt, argc, argv, 1, "hu:t:s:k:", longopts)) >= 0) {
        if (c == 'h') { usage_create(); exit(0); }
        if (c == 'u') { user = opt.arg; continue; }
        if (c == 't') { template_name = opt.arg; continue; }
        if (c == 's') { size = opt.arg; continue; }
        if (c == 'k') { token = opt.arg; continue; }
        cli_parse_error("sandbox", "create --user <id> [--template <name>] [--size <small|medium|large|xlarge>] [--token <api-key>]", argc, argv, &opt, c);
    }
    if (opt.ind != argc) cli_usage_error("sandbox", "create --user <id> [--template <name>] [--size <small|medium|large|xlarge>] [--token <api-key>]", "unexpected argument");
    if (!user) cli_usage_error("sandbox", "create --user <id> [--template <name>] [--size <small|medium|large|xlarge>] [--token <api-key>]", "missing --user");

    char payload[512];
    json_buf_t jb;
    jb_init(&jb, payload, sizeof(payload));
    jb_obj_open(&jb);
    jb_str(&jb, "user_id", user);
    jb_str(&jb, "template", template_name);
    jb_str(&jb, "size", size);
    jb_str(&jb, "edge_token", token);
    jb_obj_close(&jb);
    if (jb.overflow) fatal("payload too large");
    payload[jb.len] = '\0';
    build_and_run("sandbox.create", payload);
}

static void cmd_template_list(int argc, char **argv) {
    parse_no_args("template list", usage_template_list, argc, argv);
    build_and_run("templates.list", NULL);
}

static void cmd_template_create(int argc, char **argv) {
    const char *name = NULL, *kernel = NULL, *rootfs = NULL, *boot_args = NULL, *description = NULL;
    const char *packages[MAX_PACKAGES];
    size_t package_count = 0;
    ketopt_t opt = KETOPT_INIT;
    ko_longopt_t longopts[] = {
        { "help", ko_no_argument, 'h' },
        { "kernel", ko_required_argument, 'k' },
        { "rootfs", ko_required_argument, 'r' },
        { "boot-args", ko_required_argument, 'b' },
        { "description", ko_required_argument, 'd' },
        { "package", ko_required_argument, 'p' },
        { 0, 0, 0 }
    };
    int c;
    while ((c = ketopt(&opt, argc, argv, 1, "hk:r:b:d:p:", longopts)) >= 0) {
        if (c == 'h') { usage_template_create(); exit(0); }
        if (c == 'k') { kernel = opt.arg; continue; }
        if (c == 'r') { rootfs = opt.arg; continue; }
        if (c == 'b') { boot_args = opt.arg; continue; }
        if (c == 'd') { description = opt.arg; continue; }
        if (c == 'p') {
            if (package_count == MAX_PACKAGES) fatal("too many --package values");
            packages[package_count++] = opt.arg;
            continue;
        }
        cli_parse_error("sandbox", "template create <name> --kernel <path> --rootfs <path> [--boot-args <args>] [--description <text>] [--package <name> ...]", argc, argv, &opt, c);
    }
    if (opt.ind >= argc) cli_usage_error("sandbox", "template create <name> --kernel <path> --rootfs <path> [--boot-args <args>] [--description <text>] [--package <name> ...]", "missing <name>");
    name = argv[opt.ind++];
    if (opt.ind != argc) cli_usage_error("sandbox", "template create <name> --kernel <path> --rootfs <path> [--boot-args <args>] [--description <text>] [--package <name> ...]", "unexpected argument");
    if (!kernel || !rootfs) cli_usage_error("sandbox", "template create <name> --kernel <path> --rootfs <path> [--boot-args <args>] [--description <text>] [--package <name> ...]", "missing --kernel or --rootfs");

    char payload[2048];
    json_buf_t jb;
    jb_init(&jb, payload, sizeof(payload));
    jb_obj_open(&jb);
    jb_str(&jb, "name", name);
    jb_str(&jb, "kernel_path", kernel);
    jb_str(&jb, "rootfs_path", rootfs);
    jb_str(&jb, "boot_args", boot_args);
    jb_str(&jb, "description", description);
    if (package_count) {
        jb_escaped(&jb, "packages");
        jb_char(&jb, ':');
        jb_char(&jb, '[');
        for (size_t i = 0; i < package_count; i++) {
            if (i) jb_char(&jb, ',');
            jb_escaped(&jb, packages[i]);
        }
        jb_char(&jb, ']');
        jb_char(&jb, ',');
    }
    jb_obj_close(&jb);
    if (jb.overflow) fatal("payload too large");
    payload[jb.len] = '\0';
    build_and_run("template.create", payload);
}

// ── Main ──────────────────────────────────────────────────────────────────────

int main(int argc, char **argv) {
    if (argc < 2) {
        usage();
        return 1;
    }
    if (cli_is_help(argv[1])) {
        usage();
        return 0;
    }

    if (!strcmp(argv[1], "login")) {
        cmd_login(argc - 1, argv + 1);
    } else if (!strcmp(argv[1], "health")) {
        cmd_health(argc - 1, argv + 1);
    } else if (!strcmp(argv[1], "stats")) {
        cmd_stats(argc - 1, argv + 1);
    } else if (!strcmp(argv[1], "list")) {
        cmd_list(argc - 1, argv + 1);
    } else if (!strcmp(argv[1], "get")) {
        cmd_id_request("get", "sandbox.get", argc - 1, argv + 1);
    } else if (!strcmp(argv[1], "delete")) {
        cmd_id_request("delete", "sandbox.delete", argc - 1, argv + 1);
    } else if (!strcmp(argv[1], "pause")) {
        cmd_id_request("pause", "sandbox.pause", argc - 1, argv + 1);
    } else if (!strcmp(argv[1], "resume")) {
        cmd_id_request("resume", "sandbox.resume", argc - 1, argv + 1);
    } else if (!strcmp(argv[1], "create")) {
        cmd_create(argc - 1, argv + 1);
    } else if (!strcmp(argv[1], "template")) {
        if (argc < 3) {
            cli_usage_error("sandbox", "template <list|create> ...", "missing template subcommand");
        }
        if (cli_is_help(argv[2])) {
            cli_usage(stdout, "sandbox", "template <list|create> ...");
            return 0;
        }
        if (!strcmp(argv[2], "list")) {
            cmd_template_list(argc - 2, argv + 2);
        } else if (!strcmp(argv[2], "create")) {
            cmd_template_create(argc - 2, argv + 2);
        } else {
            cli_usage_error("sandbox", "template <list|create> ...", "unknown template subcommand");
        }
    } else {
        usage();
        return 1;
    }
    return 0;
}
