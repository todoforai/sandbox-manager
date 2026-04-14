#!/bin/bash
# Build Alpine Linux rootfs for Firecracker
set -e

ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ARCH="x86_64"
ROOTFS_DIR="./rootfs"
OUTPUT="${OUTPUT:-rootfs.ext4}"
SIZE_MB="${SIZE_MB:-500}"

echo "Building Alpine $ALPINE_VERSION rootfs..."

# Download Alpine minirootfs
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"
if [ ! -f alpine.tar.gz ]; then
    echo "Downloading Alpine minirootfs..."
    wget -q "$ALPINE_URL" -O alpine.tar.gz
fi

# Create rootfs directory
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
tar -xzf alpine.tar.gz -C "$ROOTFS_DIR"

# Setup script to run inside chroot
cat > "$ROOTFS_DIR/setup.sh" << 'SETUP_EOF'
#!/bin/sh
set -e

# Setup DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Update and install packages
apk update
apk add --no-cache \
    bash \
    openrc \
    curl \
    wget \
    git \
    openssh-client \
    ca-certificates \
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
    openssl \
    nodejs \
    npm \
    python3 \
    py3-pip \
    py3-setuptools \
    tzdata

# Enable OpenRC services
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add networking boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add syslog boot

# Set hostname
echo "sandbox" > /etc/hostname

# Configure networking (DHCP)
cat > /etc/network/interfaces << 'NETEOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NETEOF

# Configure inittab for serial console
cat > /etc/inittab << 'INITEOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
INITEOF

# Create edge-agent placeholder
mkdir -p /usr/local/bin
cat > /usr/local/bin/edge-agent << 'AGENT_EOF'
#!/bin/bash
echo "Edge agent placeholder - replace with real agent"
exec /bin/bash
AGENT_EOF
chmod +x /usr/local/bin/edge-agent

# Remove unnecessary files to save space
rm -rf /usr/share/man /usr/share/doc /usr/share/info
rm -rf /var/cache/apk/*
rm -rf /tmp/*

# Lock root account (no password login)
# For debugging, use: echo "root:sandbox" | chpasswd
passwd -l root

echo "Setup complete!"
SETUP_EOF

chmod +x "$ROOTFS_DIR/setup.sh"

# Run setup in chroot
echo "Running setup in chroot..."
if command -v arch-chroot &> /dev/null; then
    arch-chroot "$ROOTFS_DIR" /setup.sh
else
    # Fallback: mount necessary filesystems manually
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys "$ROOTFS_DIR/sys"
    chroot "$ROOTFS_DIR" /setup.sh
    umount "$ROOTFS_DIR/sys"
    umount "$ROOTFS_DIR/proc"
    umount "$ROOTFS_DIR/dev"
fi

rm "$ROOTFS_DIR/setup.sh"

# Create ext4 image
echo "Creating ext4 image ($SIZE_MB MB)..."
dd if=/dev/zero of="$OUTPUT" bs=1M count="$SIZE_MB" status=progress
mkfs.ext4 -d "$ROOTFS_DIR" -L rootfs "$OUTPUT"

# Show result
echo ""
echo "Created: $OUTPUT"
ls -lh "$OUTPUT"
echo ""
echo "Contents:"
du -sh "$ROOTFS_DIR"/*
