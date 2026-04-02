//! Template management
//!
//! Templates are pre-built VM snapshots that can be forked instantly.
//! Each template includes:
//! - Kernel image (vmlinux)
//! - Root filesystem (rootfs.ext4 or rootfs.squashfs)
//! - Memory snapshot (memory.snap)
//! - CPU state snapshot (vmstate.snap)

pub mod builder;
