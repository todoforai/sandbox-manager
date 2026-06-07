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
# bubblewrap, no kernel. Each exec runs in a per-sandbox network namespace
# attached to br-sandbox-lite; egress is filtered by nftables — see
# scripts/ensure-bridge-lite.sh (allow 53/80/443, drop RFC1918, loopback,
# link-local, SMTP, SSH). Install via systemd/install.sh.

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

# Browser tooling (section 2d). agent-browser is a static-musl Rust CLI that
# drives a browser engine over CDP; lightpanda is a tiny headless engine and
# the Lite default. Chromium is the full-fidelity engine but adds ~400 MB +
# runtime scaffolding, so it's opt-in (LITE_BUNDLE_CHROMIUM=1). Versions are
# pinned for reproducibility; override via env.
AGENT_BROWSER_VERSION="${AGENT_BROWSER_VERSION:-0.27.1}"
LIGHTPANDA_VERSION="${LIGHTPANDA_VERSION:-0.3.1}"
LITE_BUNDLE_CHROMIUM="${LITE_BUNDLE_CHROMIUM:-0}"

echo "==> Building cli-lite template at $TEMPLATE_DIR"

# cli-lite bundles the todoai CLI ($REPO_ROOT/cli) and the tfa-* tools
# ($REPO_ROOT/api-apps) — both large bun workspaces that live only in the
# monorepo. A standalone clone (prod deploy) has neither, so build cli-lite in
# the monorepo and ship the rootfs to $TEMPLATES_DIR/cli-lite instead. Skip
# cleanly here rather than fail a combined `provision-templates all` run.
if [ ! -d "$CLI_DIR" ] || [ ! -d "$API_APPS_DIR" ]; then
    echo "==> SKIP cli-lite: monorepo sources absent (CLI_DIR=$CLI_DIR, API_APPS_DIR=$API_APPS_DIR)."
    echo "    Build cli-lite in the monorepo and rsync $TEMPLATE_DIR to the host."
    exit 0
fi

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

# 1a. Bundle each TOOL_CATALOG entry tagged `preinstallCloud: true` with
#     installer == "npm" or "bun" (both publish to the npm registry and use
#     the same api-apps source layout). `todoai` is excluded here because
#     it lives in cli/ — not api-apps/ — and is already compiled above.
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
        | map(select(.value.preinstallCloud == true and (.value.installer == "npm" or .value.installer == "bun")))
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
        # Catalog key usually == api-apps dir name, but some packages live in a
        # differently-named dir (e.g. catalog `tfa-vault` → api-apps/vault,
        # whose package.json declares `bin: { "tfa-vault": … }`). Fall back to
        # the package whose `bin` declares this key.
        if [ ! -f "$entry" ]; then
            for pj in "$API_APPS_DIR"/*/package.json; do
                if jq -e --arg k "$key" '(.bin|objects)|has($k)' "$pj" >/dev/null 2>&1; then
                    src_dir="$(dirname "$pj")"; entry="$src_dir/src/cli.ts"; break
                fi
            done
        fi
        if [ ! -f "$entry" ]; then
            # agent-browser isn't an api-apps node CLI — it's a prebuilt binary
            # installed in section 2d. Skip quietly here to avoid a misleading log.
            [ "$key" = "agent-browser" ] || echo "  skip bundle: $key (no $entry)"
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
  timeout mktemp
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
    # --remove-destination: a prior run may have replaced $dst with a symlink
    # back to $src (see the `ln -sf` in the runtimes step); without it, `cp -L`
    # dereferences that symlink and errors with "same file".
    cp -L --remove-destination "$src" "$dst"
    chmod 0755 "$dst"
    while read -r lib; do
        case "$lib" in /*) copy_lib "$lib" ;; esac
    done < <(ldd "$src" 2>/dev/null | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i }')
    echo "  added: $rel"
}
# base64 is required by the scan_tools probe (it base64-decodes every
# version/status command). Many busybox builds omit the `base64` applet, so
# pull the real coreutils binary as a guaranteed fallback — copy_bin lands it
# at /usr/bin/base64, which the busybox symlink (if any) is overwritten by.
echo "==> Copying additional binaries from host"
for b in curl jq openssl base64; do copy_bin "$b"; done

# 2b'. System-installer tools tagged `preinstallCloud: true` in TOOL_CATALOG
#      (installer == "system" → host package / static binary, not bun/npm).
#      Copied from the host with their dynamic libs, same as 2b. Best-effort:
#      skip silently if absent on the host. Covers rclone (cloud sync) etc.
#      Note: rclone FUSE `mount` won't work in the bwrap jail (no /dev/fuse,
#      no CAP_SYS_ADMIN) — but `lsf/cat/copy/sync` are HTTPS-only and do.
if [ -f "$TOOL_CATALOG_JSON" ] && command -v jq >/dev/null 2>&1; then
    SYSTEM_KEYS=$(jq -r '
        to_entries
        | map(select(.value.preinstallCloud == true and .value.installer == "system"))
        | map(.value.pkg // .key) | .[]
    ' "$TOOL_CATALOG_JSON")
    for b in $SYSTEM_KEYS; do
        # Skip tools the rootfs already provides (busybox applet or an earlier
        # copy_bin) — don't silently swap out the jail's existing utilities
        # (sed/grep/patch are busybox applets; curl was copied above). This
        # loop only adds genuinely-missing system tools like rclone.
        if [ -e "$ROOTFS/usr/bin/$b" ] || [ -e "$ROOTFS/bin/$b" ]; then
            continue
        fi
        copy_bin "$b"
        # copy_bin preserves the host path (e.g. ~/.todoforai/tools/bin/rclone),
        # which may not be on the jail PATH (/usr/bin:/bin). Symlink onto PATH.
        src="$(command -v "$b" 2>/dev/null || true)"
        if [ -n "$src" ] && [ ! -e "$ROOTFS/usr/bin/$b" ] && [ ! -e "$ROOTFS/bin/$b" ]; then
            mkdir -p "$ROOTFS/usr/bin"
            ln -sf "/${src#/}" "$ROOTFS/usr/bin/$b"
        fi
    done
fi

# 2c. Optional language runtimes — only if present on host.
#     Note: python3/node/bun are dynamically linked and carry their own
#     stdlib/runtime; we copy the runtime + its libs but NOT site-packages or
#     global npm/bun caches. Users install deps into /root themselves.
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

# 2d. Browser tooling. agent-browser (CDP controller) + lightpanda (default
#     engine). Chromium is opt-in (full fidelity, heavy). agent-browser picks
#     its engine via AGENT_BROWSER_ENGINE / --engine; lite-netns + the jail
#     give it filtered egress and DNS (section 4a).
echo "==> Installing browser tooling (agent-browser + lightpanda)"
fetch() { curl -fsSL --retry 3 -o "$1" "$2"; }  # $1=dest $2=url

# agent-browser: a single static-musl Rust binary (no deps, ~11 MB). Pull the
# linux-musl-x64 binary straight out of the npm tarball at the pinned version.
AB_TGZ="$(mktemp -d)/ab.tgz"
if fetch "$AB_TGZ" "https://registry.npmjs.org/agent-browser/-/agent-browser-${AGENT_BROWSER_VERSION}.tgz"; then
    tar -xzf "$AB_TGZ" -C "$(dirname "$AB_TGZ")" package/bin/agent-browser-linux-musl-x64 2>/dev/null \
        && install -m 0755 "$(dirname "$AB_TGZ")/package/bin/agent-browser-linux-musl-x64" "$ROOTFS/usr/bin/agent-browser" \
        && echo "  added: usr/bin/agent-browser ($AGENT_BROWSER_VERSION)"
else
    echo "  WARN: agent-browser $AGENT_BROWSER_VERSION download failed — skipping"
fi
rm -rf "$(dirname "$AB_TGZ")"

# lightpanda: headless engine, default for Lite. Dynamic (needs libc/libm —
# already present from the language runtimes). Strip to ~55 MB.
if fetch "$ROOTFS/usr/bin/lightpanda" "https://github.com/lightpanda-io/browser/releases/download/${LIGHTPANDA_VERSION}/lightpanda-x86_64-linux"; then
    chmod 0755 "$ROOTFS/usr/bin/lightpanda"
    strip -s "$ROOTFS/usr/bin/lightpanda" 2>/dev/null || true
    echo "  added: usr/bin/lightpanda ($LIGHTPANDA_VERSION)"
else
    echo "  WARN: lightpanda $LIGHTPANDA_VERSION download failed — skipping"
fi

# Chromium (opt-in): copy the host's Google Chrome install + its lib closure,
# plus the minimal runtime files headless Chrome expects (machine-id, a few
# fonts, fontconfig). agent-browser uses it via --engine chrome.
if [ "$LITE_BUNDLE_CHROMIUM" = "1" ]; then
    CHROME_DIR=""
    for d in /opt/google/chrome /opt/chromium.org/chromium; do [ -x "$d/chrome" ] && CHROME_DIR="$d" && break; done
    if [ -n "$CHROME_DIR" ]; then
        echo "==> Bundling Chromium from $CHROME_DIR (LITE_BUNDLE_CHROMIUM=1)"
        mkdir -p "$ROOTFS$CHROME_DIR"
        cp -a "$CHROME_DIR"/. "$ROOTFS$CHROME_DIR/"
        # Lib closure of the chrome binary (copy_bin only handles one level;
        # chrome dlopen's extras, so walk ldd of the main binary).
        while read -r lib; do case "$lib" in /*) copy_lib "$lib" ;; esac; done \
            < <(ldd "$CHROME_DIR/chrome" 2>/dev/null | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i }')
        ln -sf "$CHROME_DIR/chrome" "$ROOTFS/usr/bin/chrome"
        # Runtime scaffolding headless Chrome needs in the minimal jail.
        printf '00000000000000000000000000000000\n' > "$ROOTFS/etc/machine-id"
        mkdir -p "$ROOTFS/usr/share/fonts/truetype/dejavu" "$ROOTFS/etc/fonts"
        cp /usr/share/fonts/truetype/dejavu/DejaVuSans*.ttf "$ROOTFS/usr/share/fonts/truetype/dejavu/" 2>/dev/null || true
        [ -f /etc/fonts/fonts.conf ] && cp /etc/fonts/fonts.conf "$ROOTFS/etc/fonts/fonts.conf"
        echo "  added: usr/bin/chrome (+ libs, fonts, machine-id)"
    else
        echo "  WARN: LITE_BUNDLE_CHROMIUM=1 but no Chrome found on host — skipping"
    fi
fi

# 3. Mount points bwrap needs to exist in the read-only rootfs.
mkdir -p "$ROOTFS"/{root,proc,dev,tmp,etc/ssl/certs,usr/bin}

# The catalog-bundled CLIs (and many tools) use `#!/usr/bin/env node`. busybox
# `env` lives at /bin/env, so expose it at the canonical /usr/bin/env too —
# without this every `#!/usr/bin/env …` shebang fails with ENOENT.
ln -sf /bin/env "$ROOTFS/usr/bin/env"

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

# 4a. /etc/resolv.conf — DNS inside the sandbox.
#     The lite backend runs each exec in its own network namespace (not
#     --share-net to the host), and bwrap then `--ro-bind`s this rootfs over
#     `/`, so the rootfs's /etc/resolv.conf is what the jail actually reads.
#     NEVER copy the host's file: it typically points at 127.0.0.53
#     (systemd-resolved stub) which only listens on the *host's* loopback and
#     is unreachable from the netns → every lookup fails. Bake a public
#     resolver instead (egress nftables already allows 53 to public; RFC1918
#     resolvers are dropped). lite-netns.sh may still override per-netns via
#     /etc/netns/<ns>/resolv.conf for hosts that block public 53 (Hetzner).
cat > "$ROOTFS/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options edns0
EOF

# 5. Minimal /etc files so getpwuid etc. don't break.
cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
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
