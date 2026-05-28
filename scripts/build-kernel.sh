#!/bin/bash
# Build minimal Linux kernel for Firecracker
set -e

KERNEL_VERSION="${KERNEL_VERSION:-6.6}"
OUTPUT="${OUTPUT:-vmlinux}"
JOBS="${JOBS:-$(nproc)}"

echo "Building Linux kernel $KERNEL_VERSION for Firecracker..."

# Clone kernel if not exists
if [ ! -d "linux" ]; then
    echo "Cloning Linux kernel..."
    git clone --depth 1 --branch "v$KERNEL_VERSION" \
        https://github.com/torvalds/linux.git
fi

cd linux

# Start with minimal config
echo "Configuring kernel..."
make tinyconfig

# Enable required features
./scripts/config --enable CONFIG_64BIT
./scripts/config --enable CONFIG_SMP
./scripts/config --enable CONFIG_PRINTK
./scripts/config --enable CONFIG_SERIAL_8250
./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE

# Block layer — REQUIRED before VIRTIO_BLK/EXT4_FS or they get silently
# dropped by `olddefconfig` (tinyconfig disables CONFIG_BLOCK).
./scripts/config --enable CONFIG_BLOCK
./scripts/config --enable CONFIG_BLK_DEV

# Virtio (required for Firecracker)
# Firecracker uses virtio over MMIO (no PCI bus is exposed — we even pass
# `pci=off` on the kernel cmdline). Without VIRTIO_MMIO the guest kernel
# never enumerates /dev/vda and panics with "VFS: Unable to mount root fs".
#
# CONFIG_VIRTIO_MENU is REQUIRED before VIRTIO_MMIO/VIRTIO_PCI/VIRTIO_BLK
# or they get silently dropped by olddefconfig — exactly like CONFIG_BLOCK
# above. Tinyconfig leaves the virtio submenu disabled; VIRTIO_NET and
# VIRTIO_CONSOLE only sneak in because they're `select`-ed elsewhere.
./scripts/config --enable CONFIG_VIRTIO
./scripts/config --enable CONFIG_VIRTIO_MENU
./scripts/config --enable CONFIG_VIRTIO_MMIO
./scripts/config --enable CONFIG_VIRTIO_PCI
./scripts/config --enable CONFIG_VIRTIO_BLK
./scripts/config --enable CONFIG_VIRTIO_NET
./scripts/config --enable CONFIG_VIRTIO_CONSOLE
./scripts/config --enable CONFIG_VIRTIO_BALLOON
./scripts/config --enable CONFIG_HW_RANDOM_VIRTIO

# Networking
./scripts/config --enable CONFIG_NET
./scripts/config --enable CONFIG_INET
./scripts/config --enable CONFIG_NETDEVICES
./scripts/config --enable CONFIG_NET_CORE
./scripts/config --enable CONFIG_UNIX
./scripts/config --enable CONFIG_PACKET

# Filesystems
./scripts/config --enable CONFIG_EXT4_FS
./scripts/config --enable CONFIG_SQUASHFS
./scripts/config --enable CONFIG_SQUASHFS_ZSTD
./scripts/config --enable CONFIG_FUSE_FS
./scripts/config --enable CONFIG_OVERLAY_FS
./scripts/config --enable CONFIG_TMPFS
./scripts/config --enable CONFIG_PROC_FS
./scripts/config --enable CONFIG_SYSFS
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT

# Process management
./scripts/config --enable CONFIG_MULTIUSER
./scripts/config --enable CONFIG_SYSVIPC
./scripts/config --enable CONFIG_POSIX_MQUEUE
./scripts/config --enable CONFIG_CGROUPS
./scripts/config --enable CONFIG_NAMESPACES

# Vsock (for host communication)
./scripts/config --enable CONFIG_VSOCKETS
./scripts/config --enable CONFIG_VIRTIO_VSOCKETS

# TTY/PTY
./scripts/config --enable CONFIG_TTY
./scripts/config --enable CONFIG_VT
./scripts/config --enable CONFIG_UNIX98_PTYS

# Misc
./scripts/config --enable CONFIG_BINFMT_ELF
./scripts/config --enable CONFIG_BINFMT_SCRIPT
./scripts/config --enable CONFIG_EPOLL
./scripts/config --enable CONFIG_SIGNALFD
./scripts/config --enable CONFIG_TIMERFD
./scripts/config --enable CONFIG_EVENTFD
./scripts/config --enable CONFIG_AIO

# Disable unnecessary features
./scripts/config --disable CONFIG_MODULES
./scripts/config --disable CONFIG_SOUND
./scripts/config --disable CONFIG_USB
./scripts/config --disable CONFIG_WIRELESS
./scripts/config --disable CONFIG_WLAN
./scripts/config --disable CONFIG_BT
./scripts/config --disable CONFIG_INPUT
./scripts/config --disable CONFIG_VGA_CONSOLE
./scripts/config --disable CONFIG_FRAMEBUFFER
./scripts/config --disable CONFIG_DRM
./scripts/config --disable CONFIG_AGP

# Build
echo "Building kernel with $JOBS jobs..."
make olddefconfig
make -j"$JOBS" vmlinux

# Copy output. Accept absolute OUTPUT (e.g. /data/templates/.../vmlinux);
# fall back to relative (sibling of the linux/ tree) for legacy callers.
case "$OUTPUT" in
    /*) cp vmlinux "$OUTPUT" ;;
    *)  cp vmlinux "../$OUTPUT" ;;
esac

echo ""
echo "Created: $OUTPUT"
ls -lh "$OUTPUT" 2>/dev/null || ls -lh "../$OUTPUT"
