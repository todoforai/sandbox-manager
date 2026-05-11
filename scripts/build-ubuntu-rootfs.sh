#!/bin/bash
# Build Ubuntu Base rootfs for Firecracker with bridge agent pre-installed.
# Uses Ubuntu Base tarball (~30 MB) + apt for glibc + familiar userland.
# bridge is a tiny (~64KB) PTY relay that connects to todofor.ai backend.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BRIDGE_BIN="${BRIDGE_BIN:-$REPO_ROOT/bridge/build/todoforai-bridge-static}"

UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
UBUNTU_POINT="${UBUNTU_POINT:-24.04.3}"
ARCH="amd64"
ROOTFS_DIR="${ROOTFS_DIR:-/tmp/rootfs-ubuntu-build}"
OUTPUT="${OUTPUT:-rootfs-ubuntu.ext4}"
SIZE_MB="${SIZE_MB:-1500}"
PACKAGES_FILE="${PACKAGES_FILE:-$REPO_ROOT/sandbox-manager/templates/ubuntu-base.packages}"

if [ ! -f "$PACKAGES_FILE" ]; then
    echo "ERROR: package list not found: $PACKAGES_FILE" >&2
    exit 1
fi

# Strip comments & blank lines; collapse to space-separated list.
PACKAGES=$(grep -vE '^\s*(#|$)' "$PACKAGES_FILE" | tr '\n' ' ')
echo "Using package list: $PACKAGES_FILE"
echo "Packages: $PACKAGES"

echo "=========================================="
echo "Building Ubuntu $UBUNTU_VERSION rootfs with bridge"
echo "=========================================="

# Must run as root — chroot + apt need it.
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: must run as root (chroot + apt install)." >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

# Check bridge binary exists
if [ ! -f "$BRIDGE_BIN" ]; then
    echo "bridge binary not found at: $BRIDGE_BIN"
    echo "Building bridge..."
    cd "$REPO_ROOT/bridge"
    make static
    BRIDGE_BIN="$REPO_ROOT/bridge/build/todoforai-bridge-static"
fi

echo "Using bridge: $BRIDGE_BIN ($(ls -lh "$BRIDGE_BIN" | awk '{print $5}'))"

# Build version stamp — sha256 of (this script + bridge binary). Written to
# /etc/todoforai-template-version inside the rootfs and echoed by /init at
# boot, so console logs make stale rootfs immediately visible.
SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -r "$SCRIPT_PATH" ] || { echo "ERROR: build script not readable at $SCRIPT_PATH" >&2; exit 1; }
[ -r "$BRIDGE_BIN" ]  || { echo "ERROR: bridge binary not readable at $BRIDGE_BIN" >&2; exit 1; }
TEMPLATE_VERSION="$(sha256sum "$SCRIPT_PATH" "$BRIDGE_BIN" | sha256sum | cut -d' ' -f1)"
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

# /init — fetch enroll token from MMDS, redeem via `todoforai-bridge login`, then exec bridge.
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/bash
# Minimal init for Firecracker VM with bridge.
#
# Enrollment token arrives via Firecracker MMDS (169.254.169.254), not the
# kernel cmdline — /proc/cmdline is world-readable, MMDS at least bounds
# exposure to the short window between boot and redeem.

export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /root

# Print build version for log-driven staleness detection.
[ -r /etc/todoforai-template-version ] && \
    echo "[init] template-version=$(cat /etc/todoforai-template-version)"

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

# Setup networking
ip link set lo up
if ip link show eth0 >/dev/null 2>&1; then
    ip link set eth0 up

    # Parse kernel cmdline for network config
    GUEST_IP=""
    GATEWAY_IP=""
    for param in $(cat /proc/cmdline); do
        case "$param" in
            ip=*)
                # Format: ip=client_ip::gateway:netmask::interface:autoconf
                GUEST_IP=$(echo "${param#ip=}" | cut -d: -f1)
                GATEWAY_IP=$(echo "${param#ip=}" | cut -d: -f3)
                ;;
        esac
    done

    # Configure static IP if provided via cmdline
    if [ -n "$GUEST_IP" ]; then
        ip addr add "$GUEST_IP/16" dev eth0
        [ -n "$GATEWAY_IP" ] && ip route add default via "$GATEWAY_IP"
        echo "[init] Network: $GUEST_IP via $GATEWAY_IP"
    fi

    # Route to MMDS (169.254.169.254) via eth0 — needed for link-local metadata.
    ip route add 169.254.169.254 dev eth0 2>/dev/null || true
fi

# Fetch MMDS session token once, then read optional bootstrap values.
# MMDS V2 returns leaf strings JSON-encoded (surrounded by quotes) regardless
# of Accept header in our Firecracker version, so strip outer quotes.
mmds_get() {
    local raw
    raw=$(wget -q -O - --header="X-metadata-token: $MMDS_SESSION" "http://169.254.169.254/$1" 2>/dev/null || true)
    # Strip surrounding double quotes if present.
    [ "${raw#\"}" != "$raw" ] && raw="${raw#\"}" && raw="${raw%\"}"
    printf '%s' "$raw"
}
echo "[init] Fetching bootstrap data from MMDS..."
MMDS_SESSION=$(wget -q -O - --method=PUT \
    --header='X-metadata-token-ttl-seconds: 60' \
    'http://169.254.169.254/latest/api/token' 2>/dev/null || true)
ENROLL_TOKEN=""
NOISE_BACKEND_ADDR_OVR=""
NOISE_BACKEND_PUB_OVR=""
SANDBOX_ID=""
if [ -n "$MMDS_SESSION" ]; then
    ENROLL_TOKEN=$(mmds_get enroll_token)
    SANDBOX_ID=$(mmds_get sandbox_id)
    # Optional dev/non-prod overrides — point bridge at a different Noise endpoint.
    NOISE_BACKEND_ADDR_OVR=$(mmds_get noise_backend_addr)
    NOISE_BACKEND_PUB_OVR=$(mmds_get noise_backend_pub)
fi

# Give every VM a unique, human-readable hostname. The rootfs ships with
# /etc/hostname=sandbox (set at build time, see below), which would collide
# across VMs and show up as "(none)" / "sandbox" in bridge identity. Lite
# sandboxes don't use this rootfs (they use bwrap), so this branch is always
# a real VM — name it vm-<id> rather than sandbox-<id>. Always rename, even
# if SANDBOX_ID is missing (random suffix), so `uname -n` never returns the
# kernel default "(none)" that would otherwise leak into the device name.
if [ -n "$SANDBOX_ID" ] && [ "$SANDBOX_ID" != "null" ]; then
    HN="vm-$(printf '%s' "$SANDBOX_ID" | cut -c1-8)"
else
    HN="vm-$(tr -dc a-f0-9 </dev/urandom | head -c8)"
fi
echo "$HN" > /etc/hostname
# `hostname` binary may be missing in trimmed rootfs; /proc fallback always works.
hostname "$HN" 2>/dev/null || echo "$HN" > /proc/sys/kernel/hostname

if [ -n "$NOISE_BACKEND_ADDR_OVR" ] && [ "$NOISE_BACKEND_ADDR_OVR" != "null" ]; then
    # Bridge auto-selects dev port (14100) when host is local/sandbox-gateway,
    # so we only export the host. BRIDGE_PORT is the daemon's HTTP/WS port.
    export NOISE_BACKEND_HOST="${NOISE_BACKEND_ADDR_OVR%:*}"
    export BRIDGE_PORT="4000" # bridge HTTP/WS in dev (no nginx)
    echo "[init] Using NOISE_BACKEND_HOST=$NOISE_BACKEND_HOST BRIDGE_PORT=$BRIDGE_PORT"
fi
if [ -n "$NOISE_BACKEND_PUB_OVR" ] && [ "$NOISE_BACKEND_PUB_OVR" != "null" ]; then
    export NOISE_BACKEND_PUBKEY="$NOISE_BACKEND_PUB_OVR"
fi

# First-boot bootstrap: if MMDS provided a token, pass it via `login --token`.
# `bridge login` redeems and then runs the daemon in the same process — so a
# single exec covers both first boot (with token) and subsequent boots (saved
# creds in ~/.config/todoforai/credentials.json). Bridge auto-detects
# deviceType=SANDBOX from /etc/todoforai-sandbox (dropped at rootfs build);
# --device-name pins the friendly label set above (vm-<sandbox-id>).
BRIDGE_ARGS=""
if [ -n "$ENROLL_TOKEN" ] && [ "$ENROLL_TOKEN" != "null" ]; then
    echo "[init] Will redeem enrollment token (len=${#ENROLL_TOKEN}, prefix=${ENROLL_TOKEN:0:8})..."
    BRIDGE_ARGS="login --token $ENROLL_TOKEN --device-name $(cat /etc/hostname 2>/dev/null || echo unknown)"
fi

# --- Recovery SSH (vsock) bring-up ----------------------------------------
# Lock this VM's recovery principal to its sandbox id. A cert minted for a
# different sandbox is signed by the same CA but will fail principal check.
if [ -n "$SANDBOX_ID" ] && [ "$SANDBOX_ID" != "null" ]; then
    mkdir -p /etc/ssh/auth_principals
    printf 'recovery:%s\n' "$SANDBOX_ID" > /etc/ssh/auth_principals/recovery
    chmod 0644 /etc/ssh/auth_principals/recovery
fi
# First-boot host keys (rootfs is per-VM, so these are unique per sandbox).
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A >/dev/null 2>&1 || echo "[init] ssh-keygen -A failed" >&2
fi
mkdir -p /run/sshd /var/run/sshd
# Start sshd on loopback only (ListenAddress 127.0.0.1 in 10-recovery.conf).
/usr/sbin/sshd 2>/dev/null && echo "[init] sshd started (recovery channel)" || \
    echo "[init] sshd failed to start" >&2
# Bridge vsock port 22 → loopback sshd. Background; logs to console.
/usr/local/bin/recovery-vsock-bridge </dev/null >/dev/console 2>&1 &
echo "[init] vsock recovery bridge started (pid=$!)"

echo "[init] Starting bridge..."
# shellcheck disable=SC2086 # BRIDGE_ARGS intentionally word-split
exec /usr/local/bin/todoforai-bridge $BRIDGE_ARGS

# Fallback — no working bridge. Keep VM alive for debug.
if [ -t 0 ]; then
    exec /bin/bash
else
    while true; do sleep 3600; done
fi
INIT_EOF
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
    apt-get install -y --no-install-recommends $PACKAGES

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
    command -v bash curl wget jq ip ssh socat sudo >/dev/null
    echo '--- verification OK ---'

    # Generate tool manifest — human-readable list and JSON metadata.
    # Any CLI the user is likely to invoke. Missing tools render as '(missing)'.
    TOOLS='bash sh curl wget jq tar sed gawk grep find ps uname hostname ip ssh scp'
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
