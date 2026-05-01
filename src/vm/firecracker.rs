//! Firecracker process management
//!
//! Spawns and manages Firecracker processes per VM.
//! Simpler than CoW fork, production-proven (~125ms boot).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::time::{timeout, Duration};

use super::network::VmNetwork;
use super::size::VmSize;

/// Firecracker VM instance
pub struct FirecrackerVm {
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
        let mut status_line = String::new();
        reader.read_line(&mut status_line).await?;

        // Read headers until empty line
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).await?;
            if line.trim().is_empty() {
                break;
            }
        }

        // Read body (simplified - assumes small responses)
        let mut resp_body = String::new();
        let _ = timeout(Duration::from_millis(100), reader.read_line(&mut resp_body)).await;

        // Parse status code: "HTTP/1.1 204 No Content" -> 204
        let code: u16 = status_line
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        if !(200..300).contains(&code) {
            anyhow::bail!(
                "Firecracker {} {} -> {} {}",
                method, path, status_line.trim(), resp_body.trim()
            );
        }

        Ok(status_line)
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

    /// Inflate the guest balloon to `target_mib`, reclaiming that much guest RAM
    /// back to the host. Requires CONFIG_VIRTIO_BALLOON in the guest kernel.
    pub async fn balloon_set(&self, target_mib: u32) -> Result<()> {
        let body = serde_json::json!({ "amount_mib": target_mib });
        self.api_request("PATCH", "/balloon", Some(&body.to_string())).await?;
        Ok(())
    }

    /// Kill the VM process
    pub fn kill(&mut self) -> Result<()> {
        self.process.kill().ok();
        // Reap so the child doesn't linger as <defunct>. wait() blocks but the
        // process has already received SIGKILL, so it returns ~immediately.
        let _ = self.process.wait();
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
            kernel_path: PathBuf::from(format!("{}/templates/ubuntu-base/vmlinux", data_dir)),
            rootfs_path: PathBuf::from(format!("{}/templates/ubuntu-base/rootfs.ext4", data_dir)),
            boot_args: "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/init".into(),
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
        let console_log = self.runtime_dir.join(format!("{}.console.log", vm_id));
        let fc_log      = self.runtime_dir.join(format!("{}.fc.log", vm_id));

        // Remove stale sockets
        std::fs::remove_file(&socket_path).ok();
        std::fs::remove_file(&serial_path).ok();

        // Capture guest serial console (`console=ttyS0` in boot_args -> FC stdout)
        // and Firecracker's own stderr. These are the only on-disk traces of
        // what the guest /init / bridge actually did, so don't drop them.
        let console_out = std::fs::File::create(&console_log)
            .with_context(|| format!("create {}", console_log.display()))?;
        let fc_err = std::fs::File::create(&fc_log)
            .with_context(|| format!("create {}", fc_log.display()))?;

        // Spawn Firecracker process
        let process = Command::new(&self.firecracker_bin)
            .args(["--api-sock", socket_path.to_str().unwrap()])
            .stdin(Stdio::null())
            .stdout(Stdio::from(console_out))
            .stderr(Stdio::from(fc_err))
            .spawn()
            .context("Failed to spawn Firecracker")?;

        tracing::info!("VM {} logs: console={} fc={}", vm_id, console_log.display(), fc_log.display());

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
            process,
            socket_path: socket_path.clone(),
            serial_path: serial_path.clone(),
        };

        // Configure VM via API
        self.configure_vm(&vm, boot_config, size, network, enroll_token, vm_id)
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
        sandbox_id: &str,
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

        // Network interface. MMDS reachability is granted later by listing
        // this iface in `/mmds/config.network_interfaces` — Firecracker ≥1.0
        // removed the per-iface `allow_mmds_requests` field (it's serde-strict,
        // so leaving it in causes a 400 and the whole NIC creation fails).
        let net_iface = serde_json::json!({
            "iface_id": "eth0",
            "host_dev_name": network.tap_name,
            "guest_mac": network.guest_mac,
        });
        vm.api_request("PUT", "/network-interfaces/eth0", Some(&net_iface.to_string()))
            .await
            .context("Failed to configure network interface (TAP missing or Firecracker rejected config)")?;

        // Virtio-balloon — lets the host reclaim guest RAM on idle.
        // Start at 0 (no reclaim); backend can inflate via /sandbox/:id/balloon.
        // deflate_on_oom avoids killing guest processes under memory pressure.
        let balloon = serde_json::json!({
            "amount_mib": 0,
            "deflate_on_oom": true,
            "stats_polling_interval_s": 1,
        });
        if let Err(e) = vm.api_request("PUT", "/balloon", Some(&balloon.to_string())).await {
            tracing::warn!("Failed to configure balloon (guest may lack CONFIG_VIRTIO_BALLOON): {}", e);
            // Non-fatal — boot continues without balloon.
        }

        // MMDS setup. Only enable when we have a token to deliver.
        if enroll_token.is_some() {
            let mmds_config = serde_json::json!({
                "network_interfaces": ["eth0"],
                "version": "V2",
            });
            vm.api_request("PUT", "/mmds/config", Some(&mmds_config.to_string()))
                .await
                .context("Failed to configure MMDS")?;

            let mut mmds = serde_json::Map::new();
            if let Some(token) = enroll_token {
                mmds.insert("enroll_token".into(), serde_json::Value::String(token.to_string()));
            }
            mmds.insert("sandbox_id".into(), serde_json::Value::String(sandbox_id.to_string()));
            // Optional dev override: tell bridge inside the VM to talk to a non-prod
            // Noise endpoint (e.g. the local backend). Bridge falls back to its
            // hardcoded prod default when these are absent. Logged at WARN so a
            // misconfigured prod deployment is loud about redirecting guest enrollment.
            if let Ok(addr) = std::env::var("MMDS_NOISE_BACKEND_ADDR") {
                tracing::warn!("MMDS override: noise_backend_addr={}", addr);
                mmds.insert("noise_backend_addr".into(), serde_json::Value::String(addr));
            }
            if let Ok(pub_hex) = std::env::var("MMDS_NOISE_BACKEND_PUBLIC_KEY") {
                if pub_hex.len() != 64 || !pub_hex.chars().all(|c| c.is_ascii_hexdigit()) {
                    anyhow::bail!("MMDS_NOISE_BACKEND_PUBLIC_KEY must be 64 hex chars");
                }
                mmds.insert("noise_backend_pub".into(), serde_json::Value::String(pub_hex));
            }
            vm.api_request("PUT", "/mmds", Some(&serde_json::Value::Object(mmds).to_string()))
                .await
                .context("Failed to populate MMDS")?;
        }

        Ok(())
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
