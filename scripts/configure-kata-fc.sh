#!/bin/sh
set -eu

cfg=${1:-/opt/kata/share/defaults/kata-containers/configuration-fc.toml}
[ -f "$cfg" ] || { echo "Kata Firecracker config not found: $cfg" >&2; exit 1; }

# sandbox-manager uses these OCI annotations to replace Kata's 2 GiB default
# with the requested tier's Firecracker memory and vCPU allocation.
sed -i 's/^enable_annotations = .*/enable_annotations = ["enable_iommu", "virtio_fs_extra_args", "kernel_params", "default_vcpus", "default_max_vcpus", "default_memory"]/' "$cfg"

grep -q '^enable_annotations = .*"default_vcpus".*"default_max_vcpus".*"default_memory"' "$cfg" || {
    echo "Could not enable sandbox-manager resource annotations in $cfg" >&2
    exit 1
}
