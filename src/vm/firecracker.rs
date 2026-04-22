//! Firecracker process management
//!
//! Spawns and manages Firecracker processes per VM.
//! Simpler than CoW fork, production-proven (~125ms boot).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::time::{timeout, Duration};

use super::network::VmNetwork;
use super::size::VmSize;

/// Firecracker VM instance
pub struct FirecrackerVm {
    /// VM ID
    pub id: String,
    /// Firecracker process
    process: Child,
    /// API socket path
    socket_path: PathBuf,
    /// Serial console socket path
    pub serial_path: PathBuf,
}

impl FirecrackerVm {
    /// Get process ID
    pub fn pid(&self) -> u32 {
        self.process.id()
    }

    /// Check if process is still running
    pub fn is_running(&self) -> bool {
        std::process::Command::new("kill")
            .args(["-0", &self.process.id().to_string()])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    /// Send API request to Firecracker
    async fn api_request(&self, method: &str, path: &str, body: Option<&str>) -> Result<String> {
        let mut stream = UnixStream::connect(&self.socket_path)
            .await
            .context("Failed to connect to Firecracker socket")?;

        let body_str = body.unwrap_or("");
        let content_length = body_str.len();

        let request = if body.is_some() {
            format!(
                "{} {} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                method, path, content_length, body_str
            )
        } else {
            format!(
                "{} {} HTTP/1.1\r\nHost: localhost\r\n\r\n",
                method, path
            )
        };

        stream.write_all(request.as_bytes()).await?;

        let mut reader = BufReader::new(stream);
        let mut response = String::new();
        reader.read_line(&mut response).await?;

        // Read headers until empty line
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).await?;
            if line.trim().is_empty() {
                break;
            }
        }

        // Read body (simplified - assumes small responses)
        let mut body = String::new();
        let _ = timeout(Duration::from_millis(100), reader.read_line(&mut body)).await;

        Ok(response)
    }

    /// Pause the VM
    pub async fn pause(&self) -> Result<()> {
        self.api_request("PATCH", "/vm", Some(r#"{"state":"Paused"}"#))
            .await?;
        Ok(())
    }

    /// Resume the VM
    pub async fn resume(&self) -> Result<()> {
        self.api_request("PATCH", "/vm", Some(r#"{"state":"Resumed"}"#))
            .await?;
        Ok(())
    }

    /// Kill the VM process
    pub fn kill(&mut self) -> Result<()> {
        self.process.kill().ok();
        std::fs::remove_file(&self.socket_path).ok();
        std::fs::remove_file(&self.serial_path).ok();
        Ok(())
    }
}

impl Drop for FirecrackerVm {
    fn drop(&mut self) {
        self.kill().ok();
    }
}

/// Configuration for booting a Firecracker VM
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BootConfig {
    pub kernel_path: PathBuf,
    pub rootfs_path: PathBuf,
    pub boot_args: String,
}

impl Default for BootConfig {
    fn default() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        let data_dir = std::env::var("DATA_DIR")
            .unwrap_or_else(|_| format!("{}/sandbox-data", home));
        
        Self {
            kernel_path: PathBuf::from(format!("{}/templates/alpine-base/vmlinux", data_dir)),
            rootfs_path: PathBuf::from(format!("{}/templates/alpine-base/rootfs.ext4", data_dir)),
            boot_args: "console=ttyS0 reboot=k panic=1 pci=off init=/init".into(),
        }
    }
}

/// Firecracker VM launcher
pub struct FirecrackerLauncher {
    /// Path to firecracker binary
    firecracker_bin: PathBuf,
    /// Directory for runtime files (sockets, etc.)
    runtime_dir: PathBuf,
}

impl FirecrackerLauncher {
    pub fn new(runtime_dir: PathBuf) -> Result<Self> {
        // Find firecracker binary
        let firecracker_bin = which_firecracker()
            .context("Failed to find firecracker binary")?;
        
        tracing::debug!("Found firecracker at: {:?}", firecracker_bin);
        
        // Ensure runtime dir exists
        std::fs::create_dir_all(&runtime_dir)
            .with_context(|| format!("Failed to create runtime dir: {:?}", runtime_dir))?;

        Ok(Self {
            firecracker_bin,
            runtime_dir,
        })
    }

    /// Boot a new Firecracker VM
    pub async fn boot(
        &self,
        vm_id: &str,
        boot_config: &BootConfig,
        size: &VmSize,
        network: &VmNetwork,
        enroll_token: Option<&str>,
    ) -> Result<FirecrackerVm> {
        let socket_path = self.runtime_dir.join(format!("{}.sock", vm_id));
        let serial_path = self.runtime_dir.join(format!("{}.serial", vm_id));

        // Remove stale sockets
        std::fs::remove_file(&socket_path).ok();
        std::fs::remove_file(&serial_path).ok();

        // Spawn Firecracker process
        let process = Command::new(&self.firecracker_bin)
            .args(["--api-sock", socket_path.to_str().unwrap()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .context("Failed to spawn Firecracker")?;

        // Wait for socket to be ready
        for _ in 0..50 {
            if socket_path.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        if !socket_path.exists() {
            anyhow::bail!("Firecracker socket not created");
        }

        let vm = FirecrackerVm {
            id: vm_id.to_string(),
            process,
            socket_path: socket_path.clone(),
            serial_path: serial_path.clone(),
        };

        // Configure VM via API
        self.configure_vm(&vm, boot_config, size, network, enroll_token)
            .await?;

        // Start VM
        vm.api_request("PUT", "/actions", Some(r#"{"action_type":"InstanceStart"}"#))
            .await
            .context("Failed to start VM")?;

        tracing::info!("Booted Firecracker VM {} (pid: {})", vm_id, vm.pid());

        Ok(vm)
    }

    /// Configure VM before starting.
    ///
    /// The enrollment token is delivered via Firecracker MMDS (metadata service
    /// at 169.254.169.254) rather than kernel cmdline. Guest `/init` fetches
    /// it, runs `bridge login --token`, and the token is consumed.
    async fn configure_vm(
        &self,
        vm: &FirecrackerVm,
        boot_config: &BootConfig,
        size: &VmSize,
        network: &VmNetwork,
        enroll_token: Option<&str>,
    ) -> Result<()> {
        // Boot args — network only, no secret material.
        let boot_args = format!(
            "{} ip={}::{}:255.255.0.0::eth0:off",
            boot_config.boot_args, network.guest_ip, network.gateway_ip
        );

        // Boot source
        let boot_source = serde_json::json!({
            "kernel_image_path": boot_config.kernel_path,
            "boot_args": boot_args
        });
        vm.api_request("PUT", "/boot-source", Some(&boot_source.to_string()))
            .await
            .context("Failed to configure boot source")?;

        // Machine config
        let machine_config = serde_json::json!({
            "vcpu_count": size.vcpu_count(),
            "mem_size_mib": size.memory_mb()
        });
        vm.api_request("PUT", "/machine-config", Some(&machine_config.to_string()))
            .await
            .context("Failed to configure machine")?;

        // Root drive
        let drive = serde_json::json!({
            "drive_id": "rootfs",
            "path_on_host": boot_config.rootfs_path,
            "is_root_device": true,
            "is_read_only": false
        });
        vm.api_request("PUT", "/drives/rootfs", Some(&drive.to_string()))
            .await
            .context("Failed to configure drive")?;

        // Network interface — flag it as MMDS-capable so the guest can reach
        // 169.254.169.254. Without `allow_mmds_requests` the metadata server
        // drops requests from this NIC.
        let net_iface = serde_json::json!({
            "iface_id": "eth0",
            "host_dev_name": network.tap_name,
            "guest_mac": network.guest_mac,
            "allow_mmds_requests": true,
        });
        if let Err(e) = vm.api_request("PUT", "/network-interfaces/eth0", Some(&net_iface.to_string())).await {
            tracing::warn!("Failed to configure network (TAP may not exist): {}", e);
            // Continue without networking — MMDS also won't work, but boot may succeed.
            return Ok(());
        }

        // MMDS setup. Only enable when we have a token to deliver.
        if let Some(token) = enroll_token {
            let mmds_config = serde_json::json!({
                "network_interfaces": ["eth0"],
                "version": "V2",
            });
            vm.api_request("PUT", "/mmds/config", Some(&mmds_config.to_string()))
                .await
                .context("Failed to configure MMDS")?;

            let mmds_data = serde_json::json!({ "enroll_token": token });
            vm.api_request("PUT", "/mmds", Some(&mmds_data.to_string()))
                .await
                .context("Failed to populate MMDS")?;
        }

        Ok(())
    }

    /// Boot from a snapshot (faster than cold boot)
    pub async fn boot_from_snapshot(
        &self,
        vm_id: &str,
        snapshot_dir: &Path,
        network: &VmNetwork,
    ) -> Result<FirecrackerVm> {
        let socket_path = self.runtime_dir.join(format!("{}.sock", vm_id));
        let serial_path = self.runtime_dir.join(format!("{}.serial", vm_id));

        // Remove stale sockets
        std::fs::remove_file(&socket_path).ok();

        // Spawn Firecracker
        let process = Command::new(&self.firecracker_bin)
            .args(["--api-sock", socket_path.to_str().unwrap()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .context("Failed to spawn Firecracker")?;

        // Wait for socket
        for _ in 0..50 {
            if socket_path.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        let vm = FirecrackerVm {
            id: vm_id.to_string(),
            process,
            socket_path: socket_path.clone(),
            serial_path,
        };

        // Load snapshot
        let snapshot_load = serde_json::json!({
            "snapshot_path": snapshot_dir.join("vmstate.snap"),
            "mem_backend": {
                "backend_type": "File",
                "backend_path": snapshot_dir.join("memory.snap")
            },
            "enable_diff_snapshots": false,
            "resume_vm": true
        });
        vm.api_request("PUT", "/snapshot/load", Some(&snapshot_load.to_string()))
            .await
            .context("Failed to load snapshot")?;

        // Reconfigure network (TAP device changed)
        let net_iface = serde_json::json!({
            "iface_id": "eth0",
            "host_dev_name": network.tap_name
        });
        vm.api_request("PATCH", "/network-interfaces/eth0", Some(&net_iface.to_string()))
            .await
            .ok(); // May fail if network wasn't in snapshot

        tracing::info!("Restored Firecracker VM {} from snapshot", vm_id);

        Ok(vm)
    }
}

/// Find firecracker binary
fn which_firecracker() -> Result<PathBuf> {
    // Check common locations
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    let paths = [
        format!("{}/.local/bin/firecracker", home),
        "/usr/local/bin/firecracker".to_string(),
        "/usr/bin/firecracker".to_string(),
        "./firecracker".to_string(),
    ];

    for path in &paths {
        let p = PathBuf::from(path);
        if p.exists() {
            return Ok(p);
        }
    }

    // Try PATH
    if let Ok(output) = Command::new("which").arg("firecracker").output() {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                return Ok(PathBuf::from(path));
            }
        }
    }

    anyhow::bail!("Firecracker binary not found. Install from https://github.com/firecracker-microvm/firecracker/releases")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_boot_config_default() {
        let config = BootConfig::default();
        assert!(config.boot_args.contains("console=ttyS0"));
    }
}
