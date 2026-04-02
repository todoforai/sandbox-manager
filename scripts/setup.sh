#!/bin/bash
# Setup script for sandbox-manager
# Installs Firecracker and prepares the environment
set -e

FIRECRACKER_VERSION="${FIRECRACKER_VERSION:-v1.6.0}"
ARCH="x86_64"
INSTALL_DIR="/usr/local/bin"
DATA_DIR="/data"

echo "=== Sandbox Manager Setup ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./setup.sh)"
    exit 1
fi

# Check KVM
if [ ! -e /dev/kvm ]; then
    echo "ERROR: /dev/kvm not found. KVM is required."
    echo "If running in a VM, enable nested virtualization."
    exit 1
fi

# Install Firecracker
echo ""
echo "=== Installing Firecracker ${FIRECRACKER_VERSION} ==="

if command -v firecracker &>/dev/null; then
    echo "Firecracker already installed: $(firecracker --version)"
else
    RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases/download"
    TARBALL="firecracker-${FIRECRACKER_VERSION}-${ARCH}.tgz"
    
    echo "Downloading ${TARBALL}..."
    curl -sSL "${RELEASE_URL}/${FIRECRACKER_VERSION}/${TARBALL}" -o /tmp/firecracker.tgz
    
    echo "Extracting..."
    tar -xzf /tmp/firecracker.tgz -C /tmp
    
    echo "Installing to ${INSTALL_DIR}..."
    mv "/tmp/release-${FIRECRACKER_VERSION}-${ARCH}/firecracker-${FIRECRACKER_VERSION}-${ARCH}" "${INSTALL_DIR}/firecracker"
    mv "/tmp/release-${FIRECRACKER_VERSION}-${ARCH}/jailer-${FIRECRACKER_VERSION}-${ARCH}" "${INSTALL_DIR}/jailer"
    chmod +x "${INSTALL_DIR}/firecracker" "${INSTALL_DIR}/jailer"
    
    rm -rf /tmp/firecracker.tgz /tmp/release-*
    
    echo "Installed: $(firecracker --version)"
fi

# Create data directories
echo ""
echo "=== Creating directories ==="

mkdir -p "${DATA_DIR}/templates/alpine-base"
mkdir -p "${DATA_DIR}/overlays/runtime"
mkdir -p "${DATA_DIR}/snapshots"

chown -R "$(logname):$(logname)" "${DATA_DIR}" 2>/dev/null || true

echo "Created:"
echo "  ${DATA_DIR}/templates/alpine-base"
echo "  ${DATA_DIR}/overlays/runtime"
echo "  ${DATA_DIR}/snapshots"

# Setup network bridge
echo ""
echo "=== Setting up network bridge ==="

BRIDGE_NAME="br-sandbox"
BRIDGE_IP="10.0.0.1/16"

if ip link show "$BRIDGE_NAME" &>/dev/null; then
    echo "Bridge $BRIDGE_NAME already exists"
else
    echo "Creating bridge $BRIDGE_NAME..."
    ip link add "$BRIDGE_NAME" type bridge
    ip addr add "$BRIDGE_IP" dev "$BRIDGE_NAME"
    ip link set "$BRIDGE_NAME" up
    
    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # Add NAT rule
    iptables -t nat -A POSTROUTING -s 10.0.0.0/16 -j MASQUERADE
    
    # Block inter-VM traffic
    iptables -A FORWARD -i "$BRIDGE_NAME" -o "$BRIDGE_NAME" -j DROP
    
    echo "Bridge $BRIDGE_NAME created with IP $BRIDGE_IP"
fi

# Check for kernel and rootfs
echo ""
echo "=== Checking template files ==="

TEMPLATE_DIR="${DATA_DIR}/templates/alpine-base"

if [ -f "${TEMPLATE_DIR}/vmlinux" ]; then
    echo "✓ Kernel found: ${TEMPLATE_DIR}/vmlinux"
else
    echo "✗ Kernel not found"
    echo "  Run: ./scripts/build-kernel.sh"
fi

if [ -f "${TEMPLATE_DIR}/rootfs.ext4" ]; then
    echo "✓ Rootfs found: ${TEMPLATE_DIR}/rootfs.ext4"
else
    echo "✗ Rootfs not found"
    echo "  Run: ./scripts/build-rootfs.sh"
fi

# Summary
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Build kernel:  sudo ./scripts/build-kernel.sh"
echo "  2. Build rootfs:  sudo ./scripts/build-rootfs.sh"
echo "  3. Run manager:   cargo run --release"
echo ""
echo "Or use pre-built images:"
echo "  curl -sSL https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin -o ${TEMPLATE_DIR}/vmlinux"
echo "  # Then build rootfs with: sudo ./scripts/build-rootfs.sh"
