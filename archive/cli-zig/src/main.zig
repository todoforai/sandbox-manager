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
///   sandbox template create <name> --kernel <path> --rootfs <path> [--boot-args <args>]

const std = @import("std");
const noise = @import("noise");

const KEY_LEN = 32;
const MAX_FRAME = 1024 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) return usage();

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "health")) {
        return runCmd(allocator, "health.get", .{});
    } else if (std.mem.eql(u8, cmd, "stats")) {
        return runCmd(allocator, "stats.get", .{});
    } else if (std.mem.eql(u8, cmd, "list")) {
        return runCmd(allocator, "sandbox.list", .{ .user_id = flagValue(args[2..], "--user") });
    } else if (std.mem.eql(u8, cmd, "get")) {
        if (args.len < 3) return usageCmd("get <id>");
        return runCmd(allocator, "sandbox.get", .{ .id = args[2] });
    } else if (std.mem.eql(u8, cmd, "delete")) {
        if (args.len < 3) return usageCmd("delete <id>");
        return runCmd(allocator, "sandbox.delete", .{ .id = args[2] });
    } else if (std.mem.eql(u8, cmd, "pause")) {
        if (args.len < 3) return usageCmd("pause <id>");
        return runCmd(allocator, "sandbox.pause", .{ .id = args[2] });
    } else if (std.mem.eql(u8, cmd, "resume")) {
        if (args.len < 3) return usageCmd("resume <id>");
        return runCmd(allocator, "sandbox.resume", .{ .id = args[2] });
    } else if (std.mem.eql(u8, cmd, "create")) {
        const rest = args[2..];
        const user_id = flagValue(rest, "--user") orelse return usageCmd("create --user <id>");
        return runCmd(allocator, "sandbox.create", .{
            .user_id = user_id,
            .template = flagValue(rest, "--template"),
            .size = flagValue(rest, "--size"),
            .edge_token = flagValue(rest, "--token"),
        });
    } else if (std.mem.eql(u8, cmd, "template")) {
        if (args.len < 3) return usageCmd("template <list|create>");
        const sub = args[2];
        if (std.mem.eql(u8, sub, "list")) {
            return runCmd(allocator, "templates.list", .{});
        } else if (std.mem.eql(u8, sub, "create")) {
            const rest = args[3..];
            const name = if (rest.len > 0 and rest[0][0] != '-') rest[0] else return usageCmd("template create <name> --kernel <path> --rootfs <path>");
            return runCmd(allocator, "template.create", .{
                .name = name,
                .kernel_path = flagValue(rest, "--kernel") orelse return usageCmd("template create <name> --kernel <path> --rootfs <path>"),
                .rootfs_path = flagValue(rest, "--rootfs") orelse return usageCmd("template create <name> --kernel <path> --rootfs <path>"),
                .boot_args = flagValue(rest, "--boot-args"),
                .description = flagValue(rest, "--description"),
            });
        } else return usageCmd("template <list|create>");
    } else {
        return usage();
    }
}

// ── Transport ─────────────────────────────────────────────────────────────────

/// Connect, perform Noise_IK handshake, send one request, print result, close.
fn runCmd(allocator: std.mem.Allocator, kind: []const u8, payload: anytype) !void {
    const local_kp = loadLocalKeypair() catch |err| fatal("NOISE_LOCAL_PRIVATE_KEY: {s}", .{@errorName(err)});
    const remote_pub = loadRemotePublic() catch |err| fatal("NOISE_REMOTE_PUBLIC_KEY: {s}", .{@errorName(err)});
    const addr = resolveAddr(allocator) catch |err| fatal("NOISE_ADDR: {s}", .{@errorName(err)});

    const stream = std.net.tcpConnectToAddress(addr) catch |err| fatal("connect: {s}", .{@errorName(err)});
    defer stream.close();

    // Handshake
    var hs = noise.HandshakeState.init(.{
        .pattern = .ik,
        .role = .initiator,
        .s = local_kp,
        .rs = remote_pub,
    }) catch |err| fatal("handshake init: {s}", .{@errorName(err)});

    // msg1: initiator -> responder
    var m1_buf: [256]u8 = undefined;
    const m1 = hs.writeMessage("", &m1_buf) catch |err| fatal("handshake write: {s}", .{@errorName(err)});
    writeFrame(stream, m1) catch |err| fatal("send handshake: {s}", .{@errorName(err)});

    // msg2: responder -> initiator
    const m2 = readFrame(allocator, stream) catch |err| fatal("recv handshake: {s}", .{@errorName(err)});
    defer allocator.free(m2);
    var p2_buf: [64]u8 = undefined;
    _ = hs.readMessage(m2, &p2_buf) catch |err| fatal("handshake read: {s}", .{@errorName(err)});

    var transport = hs.split() catch |err| fatal("handshake split: {s}", .{@errorName(err)});

    // Request
    var id_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&id_bytes);
    const req_id = std.fmt.bytesToHex(id_bytes, .lower);

    const req_json = std.json.stringifyAlloc(allocator, .{
        .id = req_id,
        .type = kind,
        .payload = payload,
    }, .{ .emit_null_optional_fields = false }) catch |err| fatal("json: {s}", .{@errorName(err)});
    defer allocator.free(req_json);

    const enc_buf = try allocator.alloc(u8, req_json.len + 64);
    defer allocator.free(enc_buf);
    const enc = transport.writeMessage(enc_buf, req_json) catch |err| fatal("encrypt: {s}", .{@errorName(err)});
    writeFrame(stream, enc) catch |err| fatal("send: {s}", .{@errorName(err)});

    // Response
    const resp_enc = readFrame(allocator, stream) catch |err| fatal("recv: {s}", .{@errorName(err)});
    defer allocator.free(resp_enc);
    const dec_buf = try allocator.alloc(u8, resp_enc.len);
    defer allocator.free(dec_buf);
    const resp = transport.readMessage(dec_buf, resp_enc) catch |err| fatal("decrypt: {s}", .{@errorName(err)});

    // Print
    const stdout = std.io.getStdOut().writer();
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch {
        try stdout.writeAll(resp);
        try stdout.writeByte('\n');
        return;
    };
    defer parsed.deinit();

    if (parsed.value.object.get("ok")) |ok_val| {
        if (ok_val == .bool and !ok_val.bool) {
            if (parsed.value.object.get("error")) |e| {
                if (e.object.get("message")) |msg| fatal("{s}", .{msg.string});
            }
        }
    }

    if (parsed.value.object.get("result")) |result| {
        try std.json.stringify(result, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeByte('\n');
    } else {
        try stdout.writeAll(resp);
        try stdout.writeByte('\n');
    }
}

// ── Framing ───────────────────────────────────────────────────────────────────

fn writeFrame(stream: std.net.Stream, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try stream.writeAll(&len_buf);
    try stream.writeAll(data);
}

fn readFrame(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try stream.reader().readNoEof(&len_buf);
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len == 0 or len > MAX_FRAME) return error.InvalidFrameLength;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try stream.reader().readNoEof(buf);
    return buf;
}

// ── Key loading ───────────────────────────────────────────────────────────────

fn loadLocalKeypair() !noise.KeyPair {
    const hex = std.posix.getenv("NOISE_LOCAL_PRIVATE_KEY") orelse return error.MissingPrivateKey;
    var secret: noise.SecretKey = undefined;
    _ = try std.fmt.hexToBytes(&secret, hex);
    const public = try std.crypto.dh.X25519.recoverPublicKey(secret);
    return .{ .secret_key = secret, .public_key = public };
}

fn loadRemotePublic() !noise.PublicKey {
    const hex = std.posix.getenv("NOISE_REMOTE_PUBLIC_KEY") orelse return error.MissingPublicKey;
    var pub_key: noise.PublicKey = undefined;
    _ = try std.fmt.hexToBytes(&pub_key, hex);
    return pub_key;
}

fn resolveAddr(allocator: std.mem.Allocator) !std.net.Address {
    const addr_str = std.posix.getenv("NOISE_ADDR") orelse "127.0.0.1:9001";
    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return error.InvalidAddr;
    const host = addr_str[0..colon];
    const port = try std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10);
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.NoAddressFound;
    return list.addrs[0];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn flagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, flag) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print(
        \\Usage: sandbox <command> [options]
        \\
        \\Commands:
        \\  health                          Health check
        \\  stats                           VM statistics
        \\  create --user <id> [opts]       Create sandbox VM
        \\    --template <name>             Template (default: alpine-base)
        \\    --size <small|medium|large|xlarge>
        \\    --token <api-key>             Auth token
        \\  list [--user <id>]              List sandboxes
        \\  get <id>                        Get sandbox details
        \\  delete <id>                     Delete sandbox
        \\  pause <id>                      Pause sandbox
        \\  resume <id>                     Resume sandbox
        \\  template list                   List templates
        \\  template create <name> --kernel <path> --rootfs <path>
        \\
        \\Env:
        \\  NOISE_ADDR              sandbox-manager Noise address (default: 127.0.0.1:9001)
        \\  NOISE_LOCAL_PRIVATE_KEY 32-byte hex private key
        \\  NOISE_REMOTE_PUBLIC_KEY 32-byte hex server public key
        \\
    , .{});
    std.process.exit(1);
}

fn usageCmd(comptime hint: []const u8) noreturn {
    fatal("Usage: sandbox " ++ hint, .{});
}
