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

# Futex — userland pthread/mutex/cond/cancellation, dl_load_lock, malloc
# arena locks all depend on it. Without it ANY glibc-linked binary aborts
# with "The futex facility returned an unexpected error code." (rc=134).
#
# tinyconfig sets EXPERT=y which exposes FUTEX as a tunable, then disables
# it. We need to undo both: re-enable FUTEX, and pull in PI/RT_MUTEXES for
# the priority-inheritance variants glibc uses on contended locks.
./scripts/config --enable CONFIG_FUTEX
./scripts/config --enable CONFIG_RT_MUTEXES
./scripts/config --enable CONFIG_FUTEX_PI

# POSIX timers — timer_create/timer_settime/clock_nanosleep family used by
# glibc/OpenSSH/cron and most non-trivial userland. Without this, the
# kernel logs "process N (foo) attempted a POSIX timer syscall while
# CONFIG_POSIX_TIMERS is not set" and the syscall returns ENOSYS — most
# callers either abort or hang. TIMERFD (already enabled below) is a
# different syscall family and does not cover this.
./scripts/config --enable CONFIG_POSIX_TIMERS

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
# Firecracker registers virtio devices via the kernel cmdline (no DT/ACPI),
# e.g. `virtio_mmio.device=4K@0xd0000000:5`. Without CMDLINE_DEVICES the
# parser is dead code, no device is probed, /dev/vda never appears →
# "VFS: Cannot open root device /dev/vda" panic at boot.
./scripts/config --enable CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES
./scripts/config --enable CONFIG_VIRTIO_PCI
./scripts/config --enable CONFIG_VIRTIO_BLK
./scripts/config --enable CONFIG_VIRTIO_NET
./scripts/config --enable CONFIG_VIRTIO_CONSOLE
./scripts/config --enable CONFIG_VIRTIO_BALLOON
# HW_RANDOM_VIRTIO is silently dropped without its HW_RANDOM parent menu
# (same olddefconfig footgun as VIRTIO_MENU). Without it the guest has no
# virtio-rng device — works but slower entropy seeding at boot.
./scripts/config --enable CONFIG_HW_RANDOM
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
# TMPFS depends on SHMEM; tinyconfig leaves SHMEM=n, dropping TMPFS silently.
./scripts/config --enable CONFIG_SHMEM
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

# Fail loud if olddefconfig silently dropped anything we need. Without this
# the resulting vmlinux boots most of the way and then panics at the first
# missing-driver step (see commits bb4b8ed, 29a98ff, ab647ad — three rounds
# of exactly this bug).
REQUIRED=(
    CONFIG_BLOCK CONFIG_BLK_DEV
    CONFIG_FUTEX CONFIG_RT_MUTEXES CONFIG_FUTEX_PI
    CONFIG_POSIX_TIMERS
    CONFIG_VIRTIO CONFIG_VIRTIO_MENU
    CONFIG_VIRTIO_MMIO CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES
    CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_VIRTIO_CONSOLE
    CONFIG_VIRTIO_BALLOON CONFIG_VIRTIO_VSOCKETS
    CONFIG_HW_RANDOM CONFIG_HW_RANDOM_VIRTIO
    CONFIG_EXT4_FS CONFIG_SHMEM CONFIG_TMPFS
    CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT
    CONFIG_NET CONFIG_INET CONFIG_NETDEVICES CONFIG_NET_CORE
    CONFIG_BINFMT_ELF CONFIG_BINFMT_SCRIPT
    CONFIG_VSOCKETS
)
missing=()
for cfg in "${REQUIRED[@]}"; do
    grep -qx "$cfg=y" .config || missing+=("$cfg")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: olddefconfig dropped required CONFIG_* options:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "Check Kconfig depends for each — usually a parent menu (VIRTIO_MENU," >&2
    echo "BLOCK, HW_RANDOM, SHMEM, etc.) is missing." >&2
    exit 1
fi

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
