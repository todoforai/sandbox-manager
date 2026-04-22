#!/bin/bash
# Build Ubuntu Base rootfs for Firecracker with bridge agent pre-installed.
# Uses Ubuntu Base tarball (~30 MB) + apt for glibc + familiar userland.
# bridge is a tiny (~64KB) PTY relay that connects to todofor.ai backend.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BRIDGE_BIN="${BRIDGE_BIN:-$REPO_ROOT/bridge/build/bridge-static}"

UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
UBUNTU_POINT="${UBUNTU_POINT:-24.04.1}"
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
    BRIDGE_BIN="$REPO_ROOT/bridge/build/bridge-static"
fi

echo "Using bridge: $BRIDGE_BIN ($(ls -lh "$BRIDGE_BIN" | awk '{print $5}'))"

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
cp "$BRIDGE_BIN" "$ROOTFS_DIR/usr/local/bin/bridge"
chmod +x "$ROOTFS_DIR/usr/local/bin/bridge"

# /init — same logic as alpine-edge, but uses Ubuntu's ip/wget (busybox not default).
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

# Fetch enrollment token from MMDS (IMDSv2-style: session token then GET).
echo "[init] Fetching enrollment token from MMDS..."
MMDS_SESSION=$(wget -q -O - --method=PUT \
    --header='X-metadata-token-ttl-seconds: 60' \
    'http://169.254.169.254/latest/api/token' 2>/dev/null || true)
ENROLL_TOKEN=""
if [ -n "$MMDS_SESSION" ]; then
    ENROLL_TOKEN=$(wget -q -O - \
        --header="X-metadata-token: $MMDS_SESSION" \
        'http://169.254.169.254/enroll_token' 2>/dev/null || true)
fi

if [ -n "$ENROLL_TOKEN" ] && [ "$ENROLL_TOKEN" != "null" ]; then
    echo "[init] Redeeming enrollment token..."
    if /usr/local/bin/bridge login \
            --token "$ENROLL_TOKEN" \
            --device-type SANDBOX \
            --device-name "sandbox-$(cat /etc/hostname 2>/dev/null || echo unknown)"; then
        echo "[init] Starting bridge..."
        exec /usr/local/bin/bridge
    else
        echo "[init] FATAL: bridge login failed" >&2
    fi
else
    echo "[init] No enrollment token in MMDS — bridge not started" >&2
fi

# Fallback — no working bridge. Keep VM alive for debug.
if [ -t 0 ]; then
    exec /bin/bash
else
    while true; do sleep 3600; done
fi
INIT_EOF
chmod +x "$ROOTFS_DIR/init"

# Minimal /etc files (apt will overwrite resolv.conf etc. during install)
echo "sandbox" > "$ROOTFS_DIR/etc/hostname"
echo "nameserver 8.8.8.8" > "$ROOTFS_DIR/etc/resolv.conf"

# Install packages in chroot
echo "Installing packages in chroot..."
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys "$ROOTFS_DIR/sys"
trap 'umount -l "$ROOTFS_DIR/sys" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/dev" 2>/dev/null || true' EXIT

chroot "$ROOTFS_DIR" /bin/bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C
    echo 'nameserver 8.8.8.8' > /etc/resolv.conf

    apt-get update
    apt-get install -y --no-install-recommends $PACKAGES

    # Verify critical tooling is installed and runnable.
    # \`set -e\` above means any failure here aborts the whole build.
    echo '--- verification ---'
    python3 --version
    pip3 --version
    node --version
    npm --version
    git --version
    openssl version
    sqlite3 --version
    command -v bash curl wget jq make gcc >/dev/null
    echo '--- verification OK ---'

    # Generate tool manifest — human-readable list and JSON metadata.
    # Any CLI the user is likely to invoke. Missing tools render as '(missing)'.
    TOOLS='bash sh python3 pip3 node npm npx git curl wget jq zip unzip tar rsync
           make gcc g++ ld ssh scp sqlite3 openssl htop less file sed gawk grep
           find ps top uname hostname ip ping'
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
for bin in /usr/bin/python3 /usr/bin/pip3 /usr/bin/node /usr/bin/npm \
           /usr/bin/git /usr/bin/bash /usr/local/bin/bridge \
           /usr/local/bin/sandbox-tools /etc/sandbox-tools.txt \
           /etc/sandbox-manifest.json /init; do
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
echo "  /usr/local/bin/bridge         - PTY relay agent"
echo "  /usr/local/bin/sandbox-tools  - lists installed CLIs (run inside VM)"
echo "  /etc/sandbox-tools.txt        - human-readable tool manifest"
echo "  /etc/sandbox-manifest.json    - machine-readable tool manifest"
echo "  /init                         - Boot script (invoked via init=/init)"
echo "  bash, curl, wget, git, jq, zip, rsync, build-essential"
echo "  nodejs, npm, python3, python3-pip, sqlite3"
echo ""
echo "Inside the VM, run:  sandbox-tools        # pretty list"
echo "                     sandbox-tools json   # JSON manifest"
echo ""
echo "To install:"
echo "  mkdir -p ~/sandbox-data/templates/ubuntu-base"
echo "  mv $OUTPUT ~/sandbox-data/templates/ubuntu-base/rootfs.ext4"
echo "  cp ~/sandbox-data/templates/alpine-base/vmlinux ~/sandbox-data/templates/ubuntu-base/"
