module SandboxCLI

include("noise.jl")
using .NoiseProtocol
using .NoiseProtocol.NoiseCrypto
using JSON3
using Sockets

const MAX_FRAME = 1024 * 1024

# ── Framing ────────────────────────────────────────────────────────────────────

function write_frame(io::IO, data::Vector{UInt8})
    len = UInt32(length(data))
    write(io, hton(len))
    write(io, data)
end

function read_frame(io::IO)::Vector{UInt8}
    len_buf = read(io, 4)
    length(len_buf) == 4 || error("connection closed")
    len = ntoh(reinterpret(UInt32, len_buf)[1])
    (len == 0 || len > MAX_FRAME) && error("invalid frame length: $len")
    data = read(io, len)
    length(data) == len || error("truncated frame")
    data
end

# ── Key loading ────────────────────────────────────────────────────────────────

function hex2bytes_strict(s::AbstractString)::Vector{UInt8}
    s = strip(s)
    length(s) == 64 || error("key must be 64 hex chars (32 bytes), got $(length(s))")
    hex2bytes(s)
end

function load_local_keypair()::NoiseCrypto.KeyPair
    hex = get(ENV, "NOISE_LOCAL_PRIVATE_KEY", "")
    isempty(hex) && error("NOISE_LOCAL_PRIVATE_KEY not set")
    NoiseCrypto.keypair_from_secret(hex2bytes_strict(hex))
end

function load_remote_public()::Vector{UInt8}
    hex = get(ENV, "NOISE_REMOTE_PUBLIC_KEY", "")
    isempty(hex) && error("NOISE_REMOTE_PUBLIC_KEY not set")
    hex2bytes_strict(hex)
end

function resolve_addr()
    addr_str = get(ENV, "NOISE_ADDR", "127.0.0.1:9001")
    parts = rsplit(addr_str, ':'; limit=2)
    length(parts) == 2 || error("invalid NOISE_ADDR: $addr_str")
    host = String(parts[1])
    port = parse(Int, parts[2])
    (host, port)
end

# ── Transport ──────────────────────────────────────────────────────────────────

function run_cmd(kind::String, payload)
    local_kp = load_local_keypair()
    remote_pub = load_remote_public()
    host, port = resolve_addr()

    sock = connect(host, port)
    try
        # Handshake
        hs = NoiseProtocol.HandshakeState(local_kp, remote_pub)

        # msg1: initiator -> responder
        m1 = NoiseProtocol.write_message1!(hs)
        write_frame(sock, m1)

        # msg2: responder -> initiator
        m2 = read_frame(sock)
        NoiseProtocol.read_message2!(hs, m2)

        transport = NoiseProtocol.to_transport(hs)

        # Build request
        req_id = bytes2hex(rand(UInt8, 4))
        req = Dict{String,Any}("id" => req_id, "type" => kind, "payload" => payload)
        req_json = Vector{UInt8}(JSON3.write(req))

        # Encrypt and send
        encrypted = NoiseProtocol.write_transport!(transport, req_json)
        write_frame(sock, encrypted)

        # Receive and decrypt
        resp_enc = read_frame(sock)
        resp_bytes = NoiseProtocol.read_transport!(transport, resp_enc)
        resp_str = String(resp_bytes)

        # Parse and display
        resp = JSON3.read(resp_str)
        if haskey(resp, :ok) && resp[:ok] == false
            if haskey(resp, :error) && haskey(resp[:error], :message)
                fatal(resp[:error][:message])
            end
        end
        if haskey(resp, :result)
            result_str = JSON3.write(resp[:result])
            JSON3.pretty(stdout, result_str)
            println()
        else
            println(resp_str)
        end
    finally
        close(sock)
    end
end

# ── CLI helpers ────────────────────────────────────────────────────────────────

function flag_value(args, flag::String)::Union{String,Nothing}
    for i in eachindex(args)
        if args[i] == flag && i < length(args)
            return args[i + 1]
        end
    end
    nothing
end

function fatal(msg)
    printstyled(stderr, "error: ", msg, "\n"; color=:red)
    exit(1)
end

function usage()
    print(stderr, """
    Usage: sandbox <command> [options]

    Commands:
      health                          Health check
      stats                           VM statistics
      create --user <id> [opts]       Create sandbox VM
        --template <name>             Template (default: alpine-base)
        --size <small|medium|large|xlarge>
        --token <api-key>             Auth token
      list [--user <id>]              List sandboxes
      get <id>                        Get sandbox details
      delete <id>                     Delete sandbox
      pause <id>                      Pause sandbox
      resume <id>                     Resume sandbox
      template list                   List templates
      template create <name> --kernel <path> --rootfs <path>

    Env:
      NOISE_ADDR              sandbox-manager Noise address (default: 127.0.0.1:9001)
      NOISE_LOCAL_PRIVATE_KEY 32-byte hex private key
      NOISE_REMOTE_PUBLIC_KEY 32-byte hex server public key
    """)
    exit(1)
end

function usage_cmd(hint)
    fatal("Usage: sandbox $hint")
end

# ── Filter out nothing values from payload ─────────────────────────────────────

function clean_payload(d::Dict)
    Dict(k => v for (k, v) in d if v !== nothing)
end

# ── Main ───────────────────────────────────────────────────────────────────────

function main(args=ARGS)
    length(args) < 1 && usage()
    cmd = args[1]

    try
        if cmd == "health"
            run_cmd("health.get", Dict())
        elseif cmd == "stats"
            run_cmd("stats.get", Dict())
        elseif cmd == "list"
            rest = args[2:end]
            run_cmd("sandbox.list", clean_payload(Dict("user_id" => flag_value(rest, "--user"))))
        elseif cmd == "get"
            length(args) < 2 && usage_cmd("get <id>")
            run_cmd("sandbox.get", Dict("id" => args[2]))
        elseif cmd == "delete"
            length(args) < 2 && usage_cmd("delete <id>")
            run_cmd("sandbox.delete", Dict("id" => args[2]))
        elseif cmd == "pause"
            length(args) < 2 && usage_cmd("pause <id>")
            run_cmd("sandbox.pause", Dict("id" => args[2]))
        elseif cmd == "resume"
            length(args) < 2 && usage_cmd("resume <id>")
            run_cmd("sandbox.resume", Dict("id" => args[2]))
        elseif cmd == "create"
            rest = args[2:end]
            user_id = flag_value(rest, "--user")
            user_id === nothing && usage_cmd("create --user <id>")
            run_cmd("sandbox.create", clean_payload(Dict(
                "user_id" => user_id,
                "template" => flag_value(rest, "--template"),
                "size" => flag_value(rest, "--size"),
                "edge_token" => flag_value(rest, "--token"),
            )))
        elseif cmd == "template"
            length(args) < 2 && usage_cmd("template <list|create>")
            sub = args[2]
            if sub == "list"
                run_cmd("templates.list", Dict())
            elseif sub == "create"
                rest = args[3:end]
                (length(rest) < 1 || startswith(rest[1], "-")) && usage_cmd("template create <name> --kernel <path> --rootfs <path>")
                name = rest[1]
                kernel = flag_value(rest, "--kernel")
                rootfs = flag_value(rest, "--rootfs")
                (kernel === nothing || rootfs === nothing) && usage_cmd("template create <name> --kernel <path> --rootfs <path>")
                run_cmd("template.create", clean_payload(Dict(
                    "name" => name,
                    "kernel_path" => kernel,
                    "rootfs_path" => rootfs,
                    "boot_args" => flag_value(rest, "--boot-args"),
                    "description" => flag_value(rest, "--description"),
                    "packages" => flag_value(rest, "--packages"),
                )))
            else
                usage_cmd("template <list|create>")
            end
        else
            usage()
        end
    catch e
        if e isa Base.IOError || e isa EOFError
            fatal("connection failed: $(sprint(showerror, e))")
        else
            fatal(sprint(showerror, e))
        end
    end
end

end # module
