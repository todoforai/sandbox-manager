#!/bin/bash
# Build Alpine rootfs with bridge agent pre-installed
# bridge is a tiny (~64KB) PTY relay that connects to todofor.ai backend
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BRIDGE_BIN="${BRIDGE_BIN:-$REPO_ROOT/edge/bridge/zig/zig-out/bin/bridge-zig}"

ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ARCH="x86_64"
ROOTFS_DIR="${ROOTFS_DIR:-/tmp/rootfs-build}"
OUTPUT="${OUTPUT:-rootfs-edge.ext4}"
SIZE_MB="${SIZE_MB:-500}"

echo "=========================================="
echo "Building Alpine $ALPINE_VERSION rootfs with bridge"
echo "=========================================="

# Check bridge binary exists
if [ ! -f "$BRIDGE_BIN" ]; then
    echo "bridge binary not found at: $BRIDGE_BIN"
    echo "Building bridge..."
    cd "$REPO_ROOT/edge/bridge/zig"
    zig build --release=small
    BRIDGE_BIN="$REPO_ROOT/edge/bridge/zig/zig-out/bin/bridge-zig"
fi

echo "Using bridge: $BRIDGE_BIN ($(ls -lh "$BRIDGE_BIN" | awk '{print $5}'))"

# Download Alpine minirootfs
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"
if [ ! -f /tmp/alpine.tar.gz ]; then
    echo "Downloading Alpine minirootfs..."
    curl -sSL "$ALPINE_URL" -o /tmp/alpine.tar.gz
fi

# Create rootfs directory
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
tar -xzf /tmp/alpine.tar.gz -C "$ROOTFS_DIR"

# Copy bridge binary
mkdir -p "$ROOTFS_DIR/usr/local/bin"
cp "$BRIDGE_BIN" "$ROOTFS_DIR/usr/local/bin/bridge"
chmod +x "$ROOTFS_DIR/usr/local/bin/bridge"

# Create init script
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/sh
# Minimal init for Firecracker VM with bridge

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

# Setup networking
ip link set lo up
if ip link show eth0 &>/dev/null; then
    ip link set eth0 up

    # Parse kernel cmdline for network + edge config
    EDGE_TOKEN=""
    GUEST_IP=""
    GATEWAY_IP=""
    for param in $(cat /proc/cmdline); do
        case "$param" in
            edge.token=*) EDGE_TOKEN="${param#edge.token=}" ;;
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
    else
        # Fallback to DHCP
        udhcpc -i eth0 -s /bin/true -q -n 2>/dev/null || true
    fi
fi

# Start bridge if token provided
if [ -n "$EDGE_TOKEN" ]; then
    echo "[init] Starting bridge..."
    /usr/local/bin/bridge "$EDGE_TOKEN" &
    EDGE_PID=$!
    echo "[init] bridge started (pid=$EDGE_PID)"
else
    echo "[init] No edge.token in cmdline, bridge not started"
fi

# Keep running
echo "[init] VM ready"
if [ -t 0 ]; then
    # Interactive - start shell
    exec /bin/sh
else
    # Non-interactive - wait forever
    while true; do sleep 3600; done
fi
INIT_EOF
chmod +x "$ROOTFS_DIR/init"

# Create minimal /etc files
echo "sandbox" > "$ROOTFS_DIR/etc/hostname"
echo "nameserver 8.8.8.8" > "$ROOTFS_DIR/etc/resolv.conf"
echo "root:x:0:0:root:/root:/bin/sh" > "$ROOTFS_DIR/etc/passwd"
echo "root:x:0:" > "$ROOTFS_DIR/etc/group"

# Install OpenSSL (required by bridge for TLS) if running as root
if [ "$(id -u)" = "0" ]; then
    echo "Installing OpenSSL in chroot..."
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys "$ROOTFS_DIR/sys"
    
    chroot "$ROOTFS_DIR" /bin/sh -c "
        echo 'nameserver 8.8.8.8' > /etc/resolv.conf
        apk update
        apk add --no-cache \
            bash \
            curl \
            wget \
            git \
            openssh-client \
            ca-certificates \
            openssl \
            busybox-extras \
            util-linux \
            procps \
            coreutils \
            findutils \
            grep \
            sed \
            gawk \
            jq \
            zip \
            unzip \
            tar \
            rsync \
            file \
            less \
            htop \
            ncurses \
            make \
            gcc \
            g++ \
            musl-dev \
            linux-headers \
            sqlite \
            nodejs \
            npm \
            python3 \
            py3-pip \
            py3-setuptools \
            tzdata
        rm -rf /var/cache/apk/*
    "
    
    umount "$ROOTFS_DIR/sys"
    umount "$ROOTFS_DIR/proc"
    umount "$ROOTFS_DIR/dev"
else
    echo ""
    echo "WARNING: Not running as root — packages not installed. Run with sudo for full setup."
    echo ""
fi

# Create ext4 image
echo "Creating ext4 image ($SIZE_MB MB)..."
dd if=/dev/zero of="$OUTPUT" bs=1M count="$SIZE_MB" status=progress
mkfs.ext4 -d "$ROOTFS_DIR" -L rootfs "$OUTPUT"

# Show result
echo ""
echo "=========================================="
echo "Created: $OUTPUT ($(ls -lh "$OUTPUT" | awk '{print $5}'))"
echo "=========================================="
echo ""
echo "Contents:"
echo "  /usr/local/bin/bridge    - PTY relay agent"
echo "  /init                    - Boot script"
echo "  bash, curl, wget, git, jq, zip, rsync"
echo "  make, gcc, g++, musl-dev, linux-headers"
echo "  nodejs, npm, python3, py3-pip, sqlite"
echo ""
echo "Usage:"
echo "  Boot with: edge.token=<TOKEN> in kernel cmdline"
echo "  bridge connects to api.todofor.ai/ws/v2/edge-shell"
echo ""
echo "To install:"
echo "  mkdir -p ~/sandbox-data/templates/alpine-edge"
echo "  mv $OUTPUT ~/sandbox-data/templates/alpine-edge/rootfs.ext4"
echo "  cp ~/sandbox-data/templates/alpine-base/vmlinux ~/sandbox-data/templates/alpine-edge/"
