#!/usr/bin/env bash
# Build the `cli-lite` template rootfs for sandbox-manager.
#
# Layout produced:
#   $DATA_DIR/templates/cli-lite/
#     rootfs/                  ← bwrap --ro-bind '/' target
#       bin/todoai             ← compiled standalone binary (bun --compile)
#       bin/busybox            ← provides sh, ls, cat, etc.
#       bin/sh -> busybox      ← symlink so `sh -c '...'` works
#       bin/{ls,cat,grep,...}  ← busybox applet symlinks
#       bin/{curl,jq,...}      ← copied from host (with deps)
#       usr/bin/python3        ← if available on host
#       usr/bin/node           ← if available on host
#       work/, proc/, dev/, tmp/  ← empty mount points (required by bwrap)
#       etc/ssl/certs/         ← CA bundle for HTTPS calls
#     (no allowed-bins.txt — anything in the rootfs may be invoked)
#
# This is the FREE / unlogged-tier sandbox: process-level isolation via
# bubblewrap, no kernel. Network is shared with the host so HTTPS / git /
# package installs work — outbound abuse must be limited at the host firewall.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATA_DIR="${DATA_DIR:-$HOME/sandbox-data}"
TEMPLATE_DIR="$DATA_DIR/templates/cli-lite"
ROOTFS="$TEMPLATE_DIR/rootfs"

CLI_DIR="$REPO_ROOT/cli"
TODOAI_BIN_OUT="$ROOTFS/bin/todoai"
TOOL_CATALOG_JSON="${TOOL_CATALOG_JSON:-$REPO_ROOT/packages/shared-fbe/src/tool_catalog.json}"
API_APPS_DIR="${API_APPS_DIR:-$REPO_ROOT/api-apps}"
COMPILED_BINS=()

echo "==> Building cli-lite template at $TEMPLATE_DIR"

# 1. Compile todoai as a standalone binary.
#    --compile bakes the bundle in; the resulting binary will not exec
#    arbitrary JS — it only runs the embedded entrypoint.
command -v bun >/dev/null || { echo "ERROR: bun is required (https://bun.sh)"; exit 1; }

mkdir -p "$ROOTFS/bin"
echo "==> bun install (cli)"
( cd "$CLI_DIR" && bun install --frozen-lockfile 2>/dev/null || bun install )
echo "==> Compiling todoai (bun --compile) → $TODOAI_BIN_OUT"
( cd "$CLI_DIR" && bun build src/index.ts --compile --minify --target=bun-linux-x64 --outfile "$TODOAI_BIN_OUT" )
chmod 0755 "$TODOAI_BIN_OUT"
COMPILED_BINS+=("$TODOAI_BIN_OUT")

# 1a. Bundle each TOOL_CATALOG entry tagged `preinstall: true` + `installer: "npm"`.
#     Source convention: api-apps/<catalog-key>/src/cli.ts. Strategy:
#       - one bun build per tool → $ROOTFS/lib/<key>/cli.js  (~20 KB each)
#       - tiny shebang script at $ROOTFS/bin/<key> that execs node on the bundle
#     Node runtime is added below in section 2c (~80 MB once, shared by all).
#     Cli sources already use `#!/usr/bin/env node` + only `node:` stdlib so
#     they run unmodified on node.
#
#     api-apps is a bun workspace: deps like @todoforai/subagent resolve to
#     sibling packages via symlinks. Some packages (subagent) expose subpath
#     exports (`./models`) pointing at `./dist/models.js`, so the workspace
#     needs a one-shot `bun run build` first to materialize `dist/`.
if [ -f "$TOOL_CATALOG_JSON" ] && command -v jq >/dev/null 2>&1; then
    PREINSTALL_KEYS=$(jq -r '
        to_entries
        | map(select(.value.preinstall == true and .value.installer == "npm"))
        | map(.key) | .[]
    ' "$TOOL_CATALOG_JSON")
    if [ -n "$PREINSTALL_KEYS" ]; then
        echo "==> bun install (api-apps workspace)"
        ( cd "$API_APPS_DIR" && bun install --frozen-lockfile 2>/dev/null || bun install )
        # Pre-build subagent dist/ so workspace siblings can resolve its
        # subpath exports (./models). Idempotent if dist/ already exists.
        if [ -d "$API_APPS_DIR/todoforai-subagent" ]; then
            echo "==> bun run build (todoforai-subagent — resolves subpath exports)"
            ( cd "$API_APPS_DIR/todoforai-subagent" && bun run build )
        fi
    fi
    for key in $PREINSTALL_KEYS; do
        src_dir="$API_APPS_DIR/$key"
        entry="$src_dir/src/cli.ts"
        if [ ! -f "$entry" ]; then
            echo "  skip bundle: $key (no $entry)"
            continue
        fi
        bundle_dir="$ROOTFS/lib/$key"
        bundle="$bundle_dir/cli.js"
        mkdir -p "$bundle_dir"
        echo "==> Bundling $key → $bundle"
        # --target=node: emit pure-node output (no bun-specific globals).
        # No --compile, no runtime bundling — just a single JS file.
        ( cd "$src_dir" && bun build src/cli.ts --target=node --outfile "$bundle" )

        # Tiny shebang launcher. Use /usr/bin/env so it works regardless of
        # whether node lives in /usr/bin or /bin in this rootfs.
        launcher="$ROOTFS/bin/$key"
        cat > "$launcher" <<LAUNCHER_EOF
#!/bin/sh
exec /usr/bin/env node /lib/$key/cli.js "\$@"
LAUNCHER_EOF
        chmod 0755 "$launcher"
    done
else
    echo "  skip catalog bundle (no jq or no $TOOL_CATALOG_JSON)"
fi

# Bun-compiled binaries are dynamically linked against glibc. Copy the libs
# they need (and the dynamic linker) into the rootfs so bwrap can run them.
echo "==> Copying dynamic libraries for ${#COMPILED_BINS[@]} compiled binaries"
copy_lib() {
    local src="$1" dst_dir
    [ -e "$src" ] || return
    dst_dir="$ROOTFS$(dirname "$src")"
    mkdir -p "$dst_dir"
    cp -L "$src" "$dst_dir/"
}
for bin in "${COMPILED_BINS[@]}"; do
    while read -r lib; do
        case "$lib" in /*) copy_lib "$lib" ;; esac
    done < <(ldd "$bin" 2>/dev/null | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i }')
done

# 2. Ship busybox for the few POSIX utilities our CLI may shell out to.
#    Static build only — we don't want libc surprises when bwrap rebinds /.
BUSYBOX_OUT="$ROOTFS/bin/busybox"
if command -v busybox >/dev/null && file "$(command -v busybox)" 2>/dev/null | grep -q "statically linked"; then
    cp "$(command -v busybox)" "$BUSYBOX_OUT"
else
    BUSYBOX_URL="${BUSYBOX_URL:-https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox}"
    echo "==> Downloading static busybox: $BUSYBOX_URL"
    curl -fsSL "$BUSYBOX_URL" -o "$BUSYBOX_OUT"
fi
chmod 0755 "$BUSYBOX_OUT"

# 2a. Symlink common applets to busybox so `sh`, `ls`, `cat`, ... work as
#     bare names. PATH is `/usr/bin:/bin` inside the sandbox.
echo "==> Installing busybox applets"
BUSYBOX_APPLETS="sh ash ls cat cp mv rm mkdir rmdir touch echo printf
  grep sed awk find xargs head tail wc sort uniq cut tr tee
  date sleep env which dirname basename realpath readlink
  tar gzip gunzip bzip2 unzip zip
  diff patch
  ps kill pkill top free df du
  vi nano less more
  hostname uname id whoami
  base64 md5sum sha256sum sha512sum
  wget ping nslookup nc"
BUSYBOX_SUPPORTED="$($BUSYBOX_OUT --list | sort)"
for applet in $BUSYBOX_APPLETS; do
    if grep -qx "$applet" <<<"$BUSYBOX_SUPPORTED"; then
        ln -sf busybox "$ROOTFS/bin/$applet"
    else
        rm -f "$ROOTFS/bin/$applet"
        echo "  skip applet: $applet"
    fi
done

# 2b. Copy a few "real" binaries (with their dynamic libs) for things busybox
#     can't or shouldn't do: curl (TLS), jq, openssl.
#     Best-effort: skip silently if a binary isn't available on the host.
copy_bin() {
    local src
    src="$(command -v "$1" 2>/dev/null)" || { echo "  skip: $1 (not on host)"; return; }
    [ -e "$src" ] || return
    local rel="${src#/}"
    local dst="$ROOTFS/$rel"
    mkdir -p "$(dirname "$dst")"
    cp -L "$src" "$dst"
    chmod 0755 "$dst"
    while read -r lib; do
        case "$lib" in /*) copy_lib "$lib" ;; esac
    done < <(ldd "$src" 2>/dev/null | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i }')
    echo "  added: $rel"
}
echo "==> Copying additional binaries from host"
for b in curl jq openssl; do copy_bin "$b"; done

# 2c. Optional language runtimes — only if present on host.
#     Note: python3/node/bun are dynamically linked and carry their own
#     stdlib/runtime; we copy the runtime + its libs but NOT site-packages or
#     global npm/bun caches. Users install deps into /work themselves.
#     - node: required by the catalog-bundled CLI launchers above
#     - bun:  optional, gives users native TS execution + `bun install`
echo "==> Copying language runtimes"
mkdir -p "$ROOTFS/usr/bin"
for b in python3 node bun; do
    copy_bin "$b"
    src="$(command -v "$b" 2>/dev/null || true)"
    if [ -n "$src" ]; then ln -sf "/${src#/}" "$ROOTFS/usr/bin/$b"; fi
done
# python3 needs its stdlib alongside the binary
if [ -x "$ROOTFS/usr/bin/python3" ] || [ -x "$ROOTFS/bin/python3" ]; then
    py_stdlib=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])' 2>/dev/null || true)
    if [ -n "$py_stdlib" ] && [ -d "$py_stdlib" ]; then
        echo "  copying $(basename "$py_stdlib") stdlib"
        mkdir -p "$ROOTFS$(dirname "$py_stdlib")"
        cp -rL "$py_stdlib" "$ROOTFS$py_stdlib" 2>/dev/null || true
    fi
fi

# 3. Mount points bwrap needs to exist in the read-only rootfs.
mkdir -p "$ROOTFS"/{work,proc,dev,tmp,etc/ssl/certs,usr/bin}

# 4. CA certs so HTTPS works (todoai + curl consult this path).
for src in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    if [ -f "$src" ]; then cp "$src" "$ROOTFS/etc/ssl/certs/ca-certificates.crt"; break; fi
done
if [ -f "$ROOTFS/etc/ssl/certs/ca-certificates.crt" ]; then
    cp /etc/ssl/openssl.cnf "$ROOTFS/etc/ssl/openssl.cnf" 2>/dev/null || true
    ln -sf certs/ca-certificates.crt "$ROOTFS/etc/ssl/cert.pem"
    mkdir -p "$ROOTFS/usr/lib"
    ln -sfn /etc/ssl "$ROOTFS/usr/lib/ssl"
else
    echo "WARN: no CA bundle found; HTTPS may fail"
fi

# 4a. /etc/resolv.conf so DNS works inside the sandbox (net is shared with
#     host but resolv.conf is per-mount-namespace, so copy the host config).
if [ -f /etc/resolv.conf ]; then
    cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
else
    cat > "$ROOTFS/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options edns0
EOF
fi

# 5. Minimal /etc files so getpwuid etc. don't break.
cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/work:/bin/sh
EOF
cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF
cat > "$ROOTFS/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
hosts: files dns
EOF

# 6. No allow-list — anything in the rootfs may be invoked. Removed if
#    leftover from a previous build.
rm -f "$TEMPLATE_DIR/allowed-bins.txt"

echo "==> Done. Sandbox-manager will auto-discover 'cli-lite' on next start."
echo "    Rootfs:        $ROOTFS"
echo "    Allow-list:    (none — any binary in rootfs may run)"
echo "    Size:          $(du -sh "$TEMPLATE_DIR" | cut -f1)"
