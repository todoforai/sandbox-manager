#!/bin/bash
# Create a Firecracker template (snapshot) for CoW forking
set -e

TEMPLATE_NAME="${1:-alpine-base}"
KERNEL="${KERNEL:-vmlinux}"
ROOTFS="${ROOTFS:-rootfs.ext4}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/templates/$TEMPLATE_NAME}"
MEMORY_MB="${MEMORY_MB:-128}"
VCPUS="${VCPUS:-1}"

echo "Creating template: $TEMPLATE_NAME"
echo "  Kernel: $KERNEL"
echo "  Rootfs: $ROOTFS"
echo "  Memory: ${MEMORY_MB}MB"
echo "  vCPUs:  $VCPUS"

# Verify inputs exist
if [ ! -f "$KERNEL" ]; then
    echo "Error: Kernel not found: $KERNEL"
    exit 1
fi

if [ ! -f "$ROOTFS" ]; then
    echo "Error: Rootfs not found: $ROOTFS"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Copy kernel and rootfs
cp "$KERNEL" "$OUTPUT_DIR/vmlinux"
cp "$ROOTFS" "$OUTPUT_DIR/rootfs.ext4"

# Socket path
SOCKET="$OUTPUT_DIR/firecracker.sock"
rm -f "$SOCKET"

# Start Firecracker
echo "Starting Firecracker..."
firecracker --api-sock "$SOCKET" &
FC_PID=$!

# Wait for socket
for i in {1..50}; do
    [ -S "$SOCKET" ] && break
    sleep 0.1
done

if [ ! -S "$SOCKET" ]; then
    echo "Error: Firecracker socket not created"
    kill $FC_PID 2>/dev/null
    exit 1
fi

# Configure VM
echo "Configuring VM..."

# Boot source
curl --unix-socket "$SOCKET" -s -X PUT \
    -H "Content-Type: application/json" \
    -d "{
        \"kernel_image_path\": \"$OUTPUT_DIR/vmlinux\",
        \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off init=/sbin/init\"
    }" \
    "http://localhost/boot-source"

# Machine config
curl --unix-socket "$SOCKET" -s -X PUT \
    -H "Content-Type: application/json" \
    -d "{
        \"vcpu_count\": $VCPUS,
        \"mem_size_mib\": $MEMORY_MB
    }" \
    "http://localhost/machine-config"

# Root drive
curl --unix-socket "$SOCKET" -s -X PUT \
    -H "Content-Type: application/json" \
    -d "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"$OUTPUT_DIR/rootfs.ext4\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }" \
    "http://localhost/drives/rootfs"

# Start VM
echo "Starting VM..."
curl --unix-socket "$SOCKET" -s -X PUT \
    -H "Content-Type: application/json" \
    -d '{"action_type": "InstanceStart"}' \
    "http://localhost/actions"

# Wait for boot
echo "Waiting for VM to boot (10s)..."
sleep 10

# Pause VM
echo "Pausing VM..."
curl --unix-socket "$SOCKET" -s -X PATCH \
    -H "Content-Type: application/json" \
    -d '{"state": "Paused"}' \
    "http://localhost/vm"

# Create snapshot
echo "Creating snapshot..."
curl --unix-socket "$SOCKET" -s -X PUT \
    -H "Content-Type: application/json" \
    -d "{
        \"snapshot_type\": \"Full\",
        \"snapshot_path\": \"$OUTPUT_DIR/vmstate.snap\",
        \"mem_file_path\": \"$OUTPUT_DIR/memory.snap\"
    }" \
    "http://localhost/snapshot/create"

# Stop Firecracker
echo "Stopping Firecracker..."
kill $FC_PID 2>/dev/null
rm -f "$SOCKET"

# Show results
echo ""
echo "Template created: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
echo ""
echo "Total size: $(du -sh "$OUTPUT_DIR" | cut -f1)"
