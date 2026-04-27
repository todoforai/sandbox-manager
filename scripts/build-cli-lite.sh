#!/usr/bin/env bash
# Build the `cli-lite` template rootfs for sandbox-manager.
#
# Layout produced:
#   $DATA_DIR/templates/cli-lite/
#     rootfs/                  ← bwrap --ro-bind '/' target
#       bin/todoai             ← compiled standalone binary (bun --compile)
#       bin/busybox            ← provides sh, ls, cat, etc.
#       work/, proc/, dev/, tmp/  ← empty mount points (required by bwrap)
#       etc/ssl/certs/         ← CA bundle for HTTPS calls
#     allowed-bins.txt         ← argv[0] allow-list (auto-discovered by manager)
#
# This is the FREE / unlogged-tier sandbox: process-level isolation via
# bubblewrap, no kernel, no networking, no language runtime users can drive.
# `todoai` is shipped as a `bun build --compile` standalone binary so callers
# cannot smuggle arbitrary JS through it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATA_DIR="${DATA_DIR:-$HOME/sandbox-data}"
TEMPLATE_DIR="$DATA_DIR/templates/cli-lite"
ROOTFS="$TEMPLATE_DIR/rootfs"

CLI_DIR="$REPO_ROOT/cli"
TODOAI_BIN_OUT="$ROOTFS/bin/todoai"

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

# Bun-compiled binaries are dynamically linked against glibc. Copy the libs
# they need (and the dynamic linker) into the rootfs so bwrap can run them.
echo "==> Copying dynamic libraries"
copy_lib() {
    local src="$1" dst_dir
    [ -e "$src" ] || return
    dst_dir="$ROOTFS$(dirname "$src")"
    mkdir -p "$dst_dir"
    cp -L "$src" "$dst_dir/"
}
for bin in "$TODOAI_BIN_OUT"; do
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

# 3. Mount points bwrap needs to exist in the read-only rootfs.
mkdir -p "$ROOTFS"/{work,proc,dev,tmp,etc/ssl/certs}

# 4. CA certs so HTTPS works (todoai talks to api.todofor.ai).
for src in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    if [ -f "$src" ]; then cp "$src" "$ROOTFS/etc/ssl/certs/ca-certificates.crt"; break; fi
done
[ -f "$ROOTFS/etc/ssl/certs/ca-certificates.crt" ] || echo "WARN: no CA bundle found; HTTPS may fail"

# 5. Minimal /etc files so getpwuid etc. don't break.
cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/work:/bin/busybox
EOF
cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF
cat > "$ROOTFS/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
hosts: files dns
EOF

# 6. Allow-list — manager reads this file alongside the rootfs/ dir.
cat > "$TEMPLATE_DIR/allowed-bins.txt" <<'EOF'
todoai
EOF

echo "==> Done. Sandbox-manager will auto-discover 'cli-lite' on next start."
echo "    Rootfs:        $ROOTFS"
echo "    Allowed bins:  $(tr '\n' ' ' < "$TEMPLATE_DIR/allowed-bins.txt")"
echo "    Size:          $(du -sh "$TEMPLATE_DIR" | cut -f1)"
