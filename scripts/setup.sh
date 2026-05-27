#!/bin/bash
# Setup script for sandbox-manager — dev host one-time bootstrap.
# Installs Firecracker, creates data dirs, builds templates.
#
# Prod uses the equivalent path via ./deploy.sh provision-templates —
# both call scripts/build-templates.sh with the same $DATA_DIR semantics.
set -e

FIRECRACKER_VERSION="${FIRECRACKER_VERSION:-v1.6.0}"
ARCH="x86_64"
INSTALL_DIR="/usr/local/bin"
# DATA_DIR resolution mirrors build-templates.sh / build-cli-lite.sh:
#   dev default: ~/sandbox-data    (override with DATA_DIR=...)
#   prod:        /data             (set in shared/.env by deploy.sh)
DATA_DIR="${DATA_DIR:-$HOME/sandbox-data}"

echo "=== Sandbox Manager Setup ==="
echo "DATA_DIR=$DATA_DIR"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo -E ./setup.sh) — preserve env so DATA_DIR is kept"
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

# build-templates.sh creates per-template subdirs itself; we only need the
# data root + sibling dirs sandbox-manager expects to exist at startup.
mkdir -p "${DATA_DIR}/overlays/runtime" "${DATA_DIR}/snapshots"
chown -R "$(logname):$(logname)" "${DATA_DIR}" 2>/dev/null || true

# Install + start the bridge systemd unit (owns br-sandbox + NAT + forwarding)
echo ""
echo "=== Installing sandbox-bridge systemd unit ==="
"$(dirname "$0")/../systemd/install.sh"

# Build templates (idempotent: build-templates.sh skips vmlinux if it exists)
echo ""
echo "=== Building templates (same script prod uses) ==="
DATA_DIR="$DATA_DIR" "$(dirname "$0")/build-templates.sh" all

echo ""
echo "=== Setup Complete ==="
echo "Templates installed under $DATA_DIR/templates"
echo "Run manager:   ./run.sh        # dev"
