//! Template builder - creates snapshots from Firecracker VMs
//!
//! Templates are created using the shell script `scripts/create-template.sh`
//! which handles the Firecracker API calls properly.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

use crate::vm::size::VmSize;

pub struct TemplateSnapshot {
    pub memory_path: PathBuf,
    pub vmstate_path: PathBuf,
    pub memory_size: usize,
}

/// Build a template from kernel + rootfs
///
/// This delegates to the shell script for reliability.
pub async fn build_template(
    name: &str,
    kernel_path: &Path,
    rootfs_path: &Path,
    output_dir: &Path,
    size: VmSize,
) -> Result<TemplateSnapshot> {
    tokio::fs::create_dir_all(output_dir).await?;

    let memory_path = output_dir.join("memory.snap");
    let vmstate_path = output_dir.join("vmstate.snap");

    tracing::info!("Building template '{}' from {:?}", name, rootfs_path);

    // Use the shell script for template creation
    let status = std::process::Command::new("bash")
        .arg("-c")
        .arg(format!(
            "KERNEL={} ROOTFS={} OUTPUT_DIR={} MEMORY_MB={} VCPUS={} ./scripts/create-template.sh {}",
            kernel_path.display(),
            rootfs_path.display(),
            output_dir.display(),
            size.memory_mb(),
            size.vcpu_count(),
            name
        ))
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .status()
        .context("Failed to run create-template.sh")?;

    if !status.success() {
        anyhow::bail!("Template creation failed with exit code: {:?}", status.code());
    }

    // Verify output files exist
    if !memory_path.exists() {
        anyhow::bail!("Memory snapshot not created: {:?}", memory_path);
    }
    if !vmstate_path.exists() {
        anyhow::bail!("Vmstate snapshot not created: {:?}", vmstate_path);
    }

    tracing::info!(
        "Template '{}' created successfully: memory={:?}, vmstate={:?}",
        name,
        memory_path,
        vmstate_path
    );

    Ok(TemplateSnapshot {
        memory_path,
        vmstate_path,
        memory_size: (size.memory_mb() as usize) * 1024 * 1024,
    })
}

/// Verify a template exists and is valid
pub fn verify_template(template_dir: &Path) -> Result<TemplateSnapshot> {
    let memory_path = template_dir.join("memory.snap");
    let vmstate_path = template_dir.join("vmstate.snap");
    let kernel_path = template_dir.join("vmlinux");
    let rootfs_path = template_dir.join("rootfs.ext4");

    if !memory_path.exists() {
        anyhow::bail!("Memory snapshot not found: {:?}", memory_path);
    }
    if !vmstate_path.exists() {
        anyhow::bail!("Vmstate snapshot not found: {:?}", vmstate_path);
    }
    if !kernel_path.exists() {
        anyhow::bail!("Kernel not found: {:?}", kernel_path);
    }
    if !rootfs_path.exists() {
        anyhow::bail!("Rootfs not found: {:?}", rootfs_path);
    }

    // Get memory size from file
    let memory_size = std::fs::metadata(&memory_path)?.len() as usize;

    Ok(TemplateSnapshot {
        memory_path,
        vmstate_path,
        memory_size,
    })
}
