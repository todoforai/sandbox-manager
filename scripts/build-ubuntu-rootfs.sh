#!/bin/bash
# Build Ubuntu Base rootfs for Firecracker with bridge agent pre-installed.
# Uses Ubuntu Base tarball (~30 MB) + apt for glibc + familiar userland.
# bridge is a tiny (~64KB) PTY relay that connects to todofor.ai backend.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# sandbox-manager repo root (parent of scripts/) — holds templates/ and
# vendor/, valid in both the monorepo (sandbox-manager/ subdir) and the
# standalone prod clone.
SANDBOX_MGR_ROOT="$(dirname "$SCRIPT_DIR")"
# Monorepo root holds bridge/ and packages/shared-fbe/. Present only when this
# repo sits inside the monorepo; absent in the standalone prod clone, which
# instead carries vendored copies under vendor/ (see scripts/sync-vendor.sh).
REPO_ROOT="$(dirname "$SANDBOX_MGR_ROOT")"
VENDOR_DIR="$SANDBOX_MGR_ROOT/vendor"
# Resolution order for monorepo-only inputs: explicit env > vendored copy
# (standalone clone) > monorepo path (dev). Keeps dev on live source while
# making the standalone clone self-sufficient — no monorepo, no manual env.
_pick() { for p in "$@"; do [ -e "$p" ] && { echo "$p"; return; }; done; echo "$1"; }
BRIDGE_BIN="${BRIDGE_BIN:-$(_pick "$VENDOR_DIR/todoforai-bridge-static" "$REPO_ROOT/bridge/build/todoforai-bridge-static")}"

UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
UBUNTU_POINT="${UBUNTU_POINT:-24.04.3}"
ARCH="amd64"
ROOTFS_DIR="${ROOTFS_DIR:-/tmp/rootfs-ubuntu-build}"
OUTPUT="${OUTPUT:-rootfs-ubuntu.ext4}"
SIZE_MB="${SIZE_MB:-1500}"
# Package list always lives inside the sandbox-manager repo, so resolve it
# against SANDBOX_MGR_ROOT — correct in both the monorepo and standalone clone.
PACKAGES_FILE="${PACKAGES_FILE:-$SANDBOX_MGR_ROOT/templates/ubuntu-base.packages}"
TOOL_CATALOG_JSON="${TOOL_CATALOG_JSON:-$(_pick "$VENDOR_DIR/tool_catalog.json" "$REPO_ROOT/packages/shared-fbe/src/tool_catalog.json")}"
BUN_PREINSTALL_BINS=""

if [ ! -f "$PACKAGES_FILE" ]; then
    echo "ERROR: package list not found: $PACKAGES_FILE" >&2
    exit 1
fi

# Strip comments & blank lines; collapse to space-separated list.
PACKAGES=$(grep -vE '^\s*(#|$)' "$PACKAGES_FILE" | tr '\n' ' ')
echo "Using package list: $PACKAGES_FILE"
echo "Packages: $PACKAGES"

# Read packages tagged `preinstallCloud: true` from TOOL_CATALOG (single source
# of truth shared with edge/frontend). Accepts installer == "bun" or "npm" —
# both publish to the npm registry and bun installs either. Empty if catalog
# absent or jq missing.
BUN_PREINSTALL=""
if [ -f "$TOOL_CATALOG_JSON" ] && command -v jq >/dev/null 2>&1; then
    BUN_PREINSTALL=$(jq -r '
        to_entries
        | map(select(.value.preinstallCloud == true and (.value.installer == "bun" or .value.installer == "npm")))
        | map(.value.pkg) | join(" ")
    ' "$TOOL_CATALOG_JSON")
    # Catalog key = binary name on PATH (e.g. "todoforai-explore"). Used for
    # in-chroot verification and the /etc/sandbox-tools.txt manifest.
    BUN_PREINSTALL_BINS=$(jq -r '
        to_entries
        | map(select(.value.preinstallCloud == true and (.value.installer == "bun" or .value.installer == "npm")))
        | map(.key) | join(" ")
    ' "$TOOL_CATALOG_JSON")
    echo "Catalog preinstall (bun): ${BUN_PREINSTALL:-(none)}"
fi

echo "=========================================="
echo "Building Ubuntu $UBUNTU_VERSION rootfs with bridge"
echo "=========================================="

# Must run as root — chroot + apt need it.
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: must run as root (chroot + apt install)." >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

# Check bridge binary exists. In the monorepo we can build it from source; in a
# standalone clone it must be vendored (scripts/sync-vendor.sh) or passed via
# BRIDGE_BIN — there is no bridge/ to build from.
if [ ! -f "$BRIDGE_BIN" ]; then
    echo "bridge binary not found at: $BRIDGE_BIN"
    if [ -d "$REPO_ROOT/bridge" ]; then
        echo "Building bridge from $REPO_ROOT/bridge..."
        ( cd "$REPO_ROOT/bridge" && make static )
        BRIDGE_BIN="$REPO_ROOT/bridge/build/todoforai-bridge-static"
    else
        echo "ERROR: no bridge source (standalone clone) and no vendored binary." >&2
        echo "  Run scripts/sync-vendor.sh in the monorepo and commit vendor/," >&2
        echo "  or set BRIDGE_BIN=/path/to/todoforai-bridge-static." >&2
        exit 1
    fi
fi

echo "Using bridge: $BRIDGE_BIN ($(ls -lh "$BRIDGE_BIN" | awk '{print $5}'))"

# Build version stamp — sha256 of (this script + /init + bridge binary).
# Written to /etc/todoforai-template-version inside the rootfs and echoed by
# /init at boot, so console logs make stale rootfs immediately visible.
SCRIPT_PATH="${BASH_SOURCE[0]}"
INIT_PATH="$SCRIPT_DIR/rootfs/init"
[ -r "$SCRIPT_PATH" ] || { echo "ERROR: build script not readable at $SCRIPT_PATH" >&2; exit 1; }
[ -r "$INIT_PATH" ]   || { echo "ERROR: init script not readable at $INIT_PATH" >&2; exit 1; }
[ -r "$BRIDGE_BIN" ]  || { echo "ERROR: bridge binary not readable at $BRIDGE_BIN" >&2; exit 1; }
TEMPLATE_VERSION="$(sha256sum "$SCRIPT_PATH" "$INIT_PATH" "$BRIDGE_BIN" | sha256sum | cut -d' ' -f1)"
echo "Template version: $TEMPLATE_VERSION"

# Download Ubuntu Base tarball
UBUNTU_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_VERSION}/release/ubuntu-base-${UBUNTU_POINT}-base-${ARCH}.tar.gz"
if [ ! -f /tmp/ubuntu-base.tar.gz ]; then
    echo "Downloading Ubuntu Base from: $UBUNTU_URL"
    curl -fsSL "$UBUNTU_URL" -o /tmp/ubuntu-base.tar.gz
fi

# Extract rootfs
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
tar -xzf /tmp/ubuntu-base.tar.gz -C "$ROOTFS_DIR"

# Copy bridge binary
mkdir -p "$ROOTFS_DIR/usr/local/bin"
cp "$BRIDGE_BIN" "$ROOTFS_DIR/usr/local/bin/todoforai-bridge"
chmod +x "$ROOTFS_DIR/usr/local/bin/todoforai-bridge"

# Stamp the rootfs with a build version so stale rootfs is detectable.
mkdir -p "$ROOTFS_DIR/etc"
printf '%s\n' "$TEMPLATE_VERSION" > "$ROOTFS_DIR/etc/todoforai-template-version"

# /init — fetch enroll token from MMDS, redeem via `todoforai-bridge login`,
# then exec bridge. Lives in scripts/rootfs/init so it can be diff/lint/grep
# normally (heredoc-embedded scripts hide bugs — see commit history).
install -m 0755 "$SCRIPT_DIR/rootfs/init" "$ROOTFS_DIR/init"
chmod +x "$ROOTFS_DIR/init"

# Minimal /etc files. During build we bind-mount the host's resolv.conf so DNS
# works regardless of the host's setup (systemd-resolved stub, corporate DNS,
# firewalled public resolvers, etc.). The in-image resolv.conf written here is
# for the VM at boot — 8.8.8.8 is a reasonable default if the VM has egress.
echo "sandbox" > "$ROOTFS_DIR/etc/hostname"
echo "nameserver 8.8.8.8" > "$ROOTFS_DIR/etc/resolv.conf"

# Sandbox marker — bridge identity.c reads this to self-classify as DeviceType.SANDBOX
# instead of PC at enroll time. Avoids ever passing --device-type from outside.
touch "$ROOTFS_DIR/etc/todoforai-sandbox"

# --- Recovery SSH channel (vsock) ----------------------------------------
# Bake the platform recovery CA pubkey into every rootfs as the trust anchor
# for /etc/ssh/recovery_ca.pub. Source of truth: live manager (preferred) or
# the local CA file. RECOVERY_CA_PUB env can override (e.g. CI).
RECOVERY_CA_PUB_FILE="$ROOTFS_DIR/etc/ssh/recovery_ca.pub"
mkdir -p "$ROOTFS_DIR/etc/ssh"
if [ -n "${RECOVERY_CA_PUB:-}" ]; then
    printf '%s\n' "$RECOVERY_CA_PUB" > "$RECOVERY_CA_PUB_FILE"
elif [ -n "${RECOVERY_CA_URL:-}" ]; then
    curl -fsSL "$RECOVERY_CA_URL" -o "$RECOVERY_CA_PUB_FILE"
elif [ -r "${RECOVERY_CA_PATH:-${HOME:-/root}/sandbox-data/recovery_ca}" ]; then
    # Extract just the public key from the OpenSSH private key file via ssh-keygen.
    ssh-keygen -y -f "${RECOVERY_CA_PATH:-${HOME:-/root}/sandbox-data/recovery_ca}" \
        > "$RECOVERY_CA_PUB_FILE"
else
    echo "WARN: no recovery CA pubkey source — recovery SSH will reject all certs." >&2
    : > "$RECOVERY_CA_PUB_FILE"
fi
chmod 0644 "$RECOVERY_CA_PUB_FILE"
echo "Recovery CA pubkey: $(cat "$RECOVERY_CA_PUB_FILE" 2>/dev/null | head -c 60)..."

# Drop-in sshd config: trust the recovery CA only for the `recovery` user,
# and only for cert principals listed in /etc/ssh/auth_principals/recovery
# (rendered at boot from MMDS sandbox_id — locks each cert to one sandbox).
mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
cat > "$ROOTFS_DIR/etc/ssh/sshd_config.d/10-recovery.conf" << 'SSHD_EOF'
# Recovery channel — vsock-only access via the platform CA.
# sshd itself listens on loopback; socat bridges vsock:22 -> 127.0.0.1:22.
ListenAddress 127.0.0.1
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
LogLevel VERBOSE

# CA trust is scoped to the `recovery` user only — even though only that user
# has an auth_principals file, this makes the policy explicit (defense in
# depth against a future image change).
Match User recovery
    TrustedUserCAKeys /etc/ssh/recovery_ca.pub
    AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
SSHD_EOF

# Recovery user. Sudo is intentional — this is a *recovery* identity, root-equiv.
# Login is gated by an SSH cert with a sandbox-scoped principal and a TTL of
# minutes, signed only by the platform CA. No password, no static keys.
mkdir -p "$ROOTFS_DIR/etc/ssh/auth_principals"
# Boot-time /init rewrites this to `recovery:<sandbox-id>` so a cert minted
# for sandbox A is rejected by sandbox B even though both trust the same CA.
echo "recovery:UNCONFIGURED" > "$ROOTFS_DIR/etc/ssh/auth_principals/recovery"
chmod 0644 "$ROOTFS_DIR/etc/ssh/auth_principals/recovery"

# vsock<->loopback bridge runs at boot. systemd-free init: invoked from /init.
cat > "$ROOTFS_DIR/usr/local/bin/recovery-vsock-bridge" << 'BRIDGE_EOF'
#!/bin/sh
# Bridge Firecracker vsock port 22 to local sshd. Loops forever; socat exits
# per-connection with `fork`, so the outer loop only matters if socat itself
# crashes. Keep stderr → console for first-boot diagnosis.
set -eu
exec socat -d VSOCK-LISTEN:22,fork,reuseaddr TCP:127.0.0.1:22
BRIDGE_EOF
chmod +x "$ROOTFS_DIR/usr/local/bin/recovery-vsock-bridge"

# Install packages in chroot
echo "Installing packages in chroot..."
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys "$ROOTFS_DIR/sys"
# Bind-mount host resolv.conf so chroot's apt can resolve names via whatever
# DNS actually works from this host (systemd-resolved stub at 127.0.0.53, etc.).
# Follow the symlink — host's /etc/resolv.conf is usually a link to
# /run/systemd/resolve/stub-resolv.conf.
HOST_RESOLV=$(readlink -f /etc/resolv.conf)
cp "$ROOTFS_DIR/etc/resolv.conf" "$ROOTFS_DIR/etc/resolv.conf.vm"
mount --bind "$HOST_RESOLV" "$ROOTFS_DIR/etc/resolv.conf"
trap 'umount -l "$ROOTFS_DIR/etc/resolv.conf" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/dev" 2>/dev/null || true' EXIT

chroot "$ROOTFS_DIR" /bin/bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C

    apt-get update

    # HashiCorp apt repo — required because \`vault\` is not in Ubuntu's
    # default repos. Add it before the main install so vault resolves in
    # the same \`apt-get install \$PACKAGES\` call below. Bootstrap deps
    # (curl + gnupg) come from \$PACKAGES so we install those first.
    apt-get install -y --no-install-recommends curl gnupg ca-certificates
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
    chmod 0644 /etc/apt/keyrings/hashicorp-archive-keyring.gpg
    CODENAME=\$(. /etc/os-release && echo \$VERSION_CODENAME)
    echo \"deb [arch=amd64 signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \$CODENAME main\" \
        > /etc/apt/sources.list.d/hashicorp.list
    apt-get update

    apt-get install -y --no-install-recommends $PACKAGES

    # fd-find on Debian/Ubuntu installs the binary as \`fdfind\` (collision
    # with an old \`fd\` package). Catalog tool name is \`fd\`, so link it.
    if [ -x /usr/bin/fdfind ] && [ ! -e /usr/local/bin/fd ]; then
        ln -s /usr/bin/fdfind /usr/local/bin/fd
    fi

    # Install bun (replaces node+npm as runtime/package manager for catalog
    # tools). Official installer drops binary at \$BUN_INSTALL/bin/bun.
    # /usr/local/bin is already on PATH so no shell rc changes needed.
    if ! command -v bun >/dev/null 2>&1; then
        echo '--- installing bun ---'
        export BUN_INSTALL=/usr/local
        curl -fsSL https://bun.sh/install | bash
        ln -sf /usr/local/bin/bun /usr/local/bin/bunx
        # Preinstalled CLIs shebang \`#!/usr/bin/env node\`; alias node→bun
        # so they run without a separate Node.js runtime in the rootfs.
        ln -sf /usr/local/bin/bun /usr/local/bin/node
        bun --version
    fi

    # Preinstall CLI tools tagged \`preinstallCloud: true\` in TOOL_CATALOG via bun.
    # Driven from packages/shared-fbe/src/tool_catalog.json on the host —
    # values interpolated by the outer shell before chroot. BUN_INSTALL forces
    # global bins into /usr/local/bin instead of \$HOME/.bun/bin.
    if [ -n '$BUN_PREINSTALL' ]; then
        echo '--- preinstalling bun tools from TOOL_CATALOG ---'
        echo '  packages: $BUN_PREINSTALL'
        export BUN_INSTALL=/usr/local
        bun add -g $BUN_PREINSTALL
    fi

    # Recovery user: shell-able, sudo-NOPASSWD, no password, no authorized_keys.
    # Authentication is exclusively via SSH cert signed by the platform CA
    # (TrustedUserCAKeys + AuthorizedPrincipalsFile in 10-recovery.conf).
    if ! id recovery >/dev/null 2>&1; then
        useradd -m -s /bin/bash -c 'platform recovery' recovery
        passwd -l recovery >/dev/null
        # Sudo: emergency repair has to be root-equivalent to be useful.
        echo 'recovery ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/recovery-nopw
        chmod 0440 /etc/sudoers.d/recovery-nopw
    fi

    # Verify critical tooling is installed and runnable.
    # \`set -e\` above means any failure here aborts the whole build.
    # Only check what's in ubuntu-base.packages — anything heavier installs
    # on-demand inside the sandbox per the package list's stated philosophy.
    echo '--- verification ---'
    command -v bash curl wget jq ip ssh socat sudo bun >/dev/null
    if [ -n '$BUN_PREINSTALL_BINS' ]; then
        for b in $BUN_PREINSTALL_BINS; do
            command -v \"\$b\" >/dev/null || { echo \"ERROR: preinstalled tool missing on PATH: \$b\" >&2; exit 1; }
        done
    fi
    echo '--- verification OK ---'

    # Generate tool manifest — human-readable list and JSON metadata.
    # Any CLI the user is likely to invoke. Missing tools render as '(missing)'.
    TOOLS='bash sh curl wget jq tar sed gawk grep find ps uname hostname ip ssh scp bun rg fd patch rclone gh vault $BUN_PREINSTALL_BINS'
    mkdir -p /etc
    : > /etc/sandbox-tools.txt
    printf '{\n  \"distro\": \"ubuntu-base-%s\",\n  \"tools\": {\n' \"\$(. /etc/os-release && echo \$VERSION_ID)\" > /etc/sandbox-manifest.json
    first=1
    for t in \$TOOLS; do
        if command -v \$t >/dev/null 2>&1; then
            ver=\$(\$t --version 2>&1 | head -1 || echo installed)
            path=\$(command -v \$t)
            printf '%-10s %s  [%s]\n' \"\$t\" \"\$ver\" \"\$path\" >> /etc/sandbox-tools.txt
        else
            ver='(missing)'
            path=''
            printf '%-10s (missing)\n' \"\$t\" >> /etc/sandbox-tools.txt
        fi
        [ \$first -eq 0 ] && printf ',\n' >> /etc/sandbox-manifest.json
        printf '    \"%s\": {\"version\": \"%s\", \"path\": \"%s\"}' \"\$t\" \"\$ver\" \"\$path\" >> /etc/sandbox-manifest.json
        first=0
    done
    printf '\n  }\n}\n' >> /etc/sandbox-manifest.json

    # Install 'sandbox-tools' CLI shim so users can list what's available.
    cat > /usr/local/bin/sandbox-tools << 'SHIM_EOF'
#!/bin/sh
# List CLI tools installed in this sandbox.
case \"\${1:-list}\" in
    list|'')    cat /etc/sandbox-tools.txt ;;
    json)       cat /etc/sandbox-manifest.json ;;
    -h|--help)  echo 'Usage: sandbox-tools [list|json]'; exit 0 ;;
    *)          echo 'Unknown command. Try: sandbox-tools [list|json]' >&2; exit 1 ;;
esac
SHIM_EOF
    chmod +x /usr/local/bin/sandbox-tools

    echo '--- installed CLIs ---'
    cat /etc/sandbox-tools.txt

    # Shrink
    apt-get clean
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* \
           /usr/share/man/* /usr/share/doc/* /usr/share/info/* \
           /tmp/* /var/tmp/*
"

# Serial console getty via sysvinit
cat > "$ROOTFS_DIR/etc/inittab" << 'INITTAB_EOF'
id:2:initdefault:
si::sysinit:/etc/init.d/rcS
l2:2:wait:/etc/init.d/rc 2
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100
ca:12345:ctrlaltdel:/sbin/shutdown -r now
INITTAB_EOF

umount "$ROOTFS_DIR/etc/resolv.conf"
# Restore the VM-facing resolv.conf (apt may have overwritten via bind).
mv "$ROOTFS_DIR/etc/resolv.conf.vm" "$ROOTFS_DIR/etc/resolv.conf"
umount "$ROOTFS_DIR/sys"
umount "$ROOTFS_DIR/proc"
umount "$ROOTFS_DIR/dev"
trap - EXIT

# Static device nodes the kernel needs to *start* /init.
# devtmpfs gets remounted over /dev inside /init, but before /init runs the
# kernel opens /dev/console (and stdin/stdout/stderr point at it) — if the
# node is missing exec("/init") fails with ENOENT, surfacing as the very
# confusing "Requested init /init failed (error -2)" panic. mkfs.ext4 -d
# copies these into the image as real device nodes (it preserves type/major/minor).
mknod -m 622 "$ROOTFS_DIR/dev/console" c 5 1
mknod -m 666 "$ROOTFS_DIR/dev/null"    c 1 3
mknod -m 666 "$ROOTFS_DIR/dev/zero"    c 1 5
mknod -m 666 "$ROOTFS_DIR/dev/tty"     c 5 0

# Create ext4 image
echo "Creating ext4 image ($SIZE_MB MB)..."
dd if=/dev/zero of="$OUTPUT" bs=1M count="$SIZE_MB" status=progress
mkfs.ext4 -d "$ROOTFS_DIR" -L rootfs "$OUTPUT"

# Post-build sanity: mount the image and confirm binaries survived mkfs.
echo "Verifying image contents..."
VERIFY_MNT=$(mktemp -d)
mount -o loop,ro "$OUTPUT" "$VERIFY_MNT"
trap 'umount "$VERIFY_MNT" 2>/dev/null || true; rmdir "$VERIFY_MNT" 2>/dev/null || true' EXIT
for bin in /usr/bin/bash /usr/bin/curl /usr/bin/wget /usr/bin/jq \
           /usr/bin/rg /usr/local/bin/fd /usr/bin/patch \
           /usr/bin/rclone /usr/bin/gh /usr/bin/vault \
           /usr/bin/ssh \
           /usr/local/bin/bun \
           /usr/local/bin/todoforai-bridge /usr/local/bin/sandbox-tools \
           /usr/local/bin/recovery-vsock-bridge \
           /usr/sbin/sshd /usr/bin/socat /usr/bin/sudo \
           /etc/ssh/recovery_ca.pub /etc/ssh/sshd_config.d/10-recovery.conf \
           /etc/ssh/auth_principals/recovery \
           /etc/sandbox-tools.txt /etc/sandbox-manifest.json /init; do
    if [ ! -e "$VERIFY_MNT$bin" ]; then
        echo "FAIL: $bin missing from image" >&2
        exit 1
    fi
done
# Device-node sanity: missing /dev/console = kernel can't start /init.
for node in /dev/console /dev/null /dev/zero /dev/tty; do
    if [ ! -c "$VERIFY_MNT$node" ]; then
        echo "FAIL: $node missing or not a char device in image" >&2
        exit 1
    fi
done
umount "$VERIFY_MNT"
rmdir "$VERIFY_MNT"
trap - EXIT
echo "Image verification OK"

echo ""
echo "=========================================="
echo "Created: $OUTPUT ($(ls -lh "$OUTPUT" | awk '{print $5}'))"
echo "=========================================="
echo ""
echo "Contents:"
echo "  /usr/local/bin/todoforai-bridge         - PTY relay agent"
echo "  /usr/local/bin/sandbox-tools  - lists installed CLIs (run inside VM)"
echo "  /etc/sandbox-tools.txt        - human-readable tool manifest"
echo "  /etc/sandbox-manifest.json    - machine-readable tool manifest"
echo "  /init                         - Boot script (invoked via init=/init)"
echo "  bash, curl, wget, jq, openssh-server (minimal — install more on-demand inside the VM)"
echo ""
echo "Inside the VM, run:  sandbox-tools        # pretty list"
echo "                     sandbox-tools json   # JSON manifest"
echo ""
echo "To install:"
echo "  mkdir -p ~/sandbox-data/templates/ubuntu-base"
echo "  mv $OUTPUT ~/sandbox-data/templates/ubuntu-base/rootfs.ext4"
echo "  ./scripts/build-kernel.sh   # builds vmlinux into ~/sandbox-data/templates/ubuntu-base/"
