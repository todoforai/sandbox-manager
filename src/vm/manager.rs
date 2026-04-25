//! VM Manager — orchestrates VM lifecycle using Firecracker processes.
//!
//! State split:
//! - Redis (`sandbox:*`): sandbox inventory. Source of truth.
//! - In-memory `vms` DashMap: `FirecrackerVm` process handles (non-serializable).
//! - In-memory `boot_configs`: static template registry, loaded at startup.

use anyhow::{Context, Result};
use dashmap::DashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::config::{ManagerConfig, TemplateConfig};
use super::firecracker::{BootConfig, FirecrackerLauncher, FirecrackerVm};
use super::network::NetworkManager;
use super::sandbox::{Sandbox, SandboxState, SandboxStats};
use super::size::VmSize;
use crate::redis::RedisClient;

/// Per-user quota on concurrent sandboxes. TODO: read from appuser:<id>.sandboxLimit.
const DEFAULT_USER_LIMIT: usize = 10;

pub struct VmManager {
    config: ManagerConfig,
    launcher: FirecrackerLauncher,
    network: NetworkManager,
    redis: RedisClient,
    /// Running Firecracker process handles (not in Redis — non-serializable)
    vms: DashMap<String, Arc<RwLock<FirecrackerVm>>>,
    /// Static template registry
    boot_configs: DashMap<String, BootConfig>,
}

impl VmManager {
    pub async fn new(config: ManagerConfig, redis: RedisClient) -> Result<Self> {
        let runtime_dir = config.overlays_dir.join("runtime");
        let launcher = FirecrackerLauncher::new(runtime_dir)
            .context("Firecracker launcher init failed (need /dev/kvm + firecracker binary)")?;
        tracing::info!("Firecracker launcher initialized");

        let network = NetworkManager::new(&config.bridge_name, &config.network_subnet)?;
        if let Err(e) = network.init_bridge() {
            tracing::warn!("Failed to initialize bridge: {}. Networking may not work.", e);
        }

        tokio::fs::create_dir_all(&config.templates_dir).await.ok();
        tokio::fs::create_dir_all(&config.overlays_dir).await.ok();
        tokio::fs::create_dir_all(&config.snapshots_dir).await.ok();
        tokio::fs::create_dir_all(config.overlays_dir.join("runtime")).await.ok();

        let manager = Self {
            config,
            launcher,
            network,
            redis,
            vms: DashMap::new(),
            boot_configs: DashMap::new(),
        };

        // Load default template configs
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        let data_dir = std::env::var("DATA_DIR").unwrap_or_else(|_| format!("{}/sandbox-data", home));

        let ubuntu_config = BootConfig {
            kernel_path: std::path::PathBuf::from(format!("{}/templates/ubuntu-base/vmlinux", data_dir)),
            rootfs_path: std::path::PathBuf::from(format!("{}/templates/ubuntu-base/rootfs.ext4", data_dir)),
            boot_args: "console=ttyS0 reboot=k panic=1 pci=off init=/init".into(),
        };
        if ubuntu_config.kernel_path.exists() && ubuntu_config.rootfs_path.exists() {
            manager.boot_configs.insert("ubuntu-base".to_string(), ubuntu_config);
            tracing::info!("Loaded ubuntu-base template");
        } else {
            tracing::warn!(
                "ubuntu-base template not loaded: missing {} or {}",
                ubuntu_config.kernel_path.display(),
                ubuntu_config.rootfs_path.display()
            );
        }

        let alpine_config = BootConfig {
            kernel_path: std::path::PathBuf::from(format!("{}/templates/alpine-base/vmlinux", data_dir)),
            rootfs_path: std::path::PathBuf::from(format!("{}/templates/alpine-base/rootfs.ext4", data_dir)),
            boot_args: "console=ttyS0 reboot=k panic=1 pci=off init=/sbin/init".into(),
        };
        if alpine_config.kernel_path.exists() && alpine_config.rootfs_path.exists() {
            manager.boot_configs.insert("alpine-base".to_string(), alpine_config);
            tracing::info!("Loaded alpine-base template");
        } else {
            tracing::debug!("alpine-base template not present (optional)");
        }

        let edge_config = BootConfig {
            kernel_path: std::path::PathBuf::from(format!("{}/templates/alpine-edge/vmlinux", data_dir)),
            rootfs_path: std::path::PathBuf::from(format!("{}/templates/alpine-edge/rootfs.ext4", data_dir)),
            boot_args: "console=ttyS0 reboot=k panic=1 pci=off init=/init".into(),
        };
        if edge_config.kernel_path.exists() && edge_config.rootfs_path.exists() {
            manager.boot_configs.insert("alpine-edge".to_string(), edge_config);
            tracing::info!("Loaded alpine-edge template");
        } else {
            tracing::debug!("alpine-edge template not present (optional)");
        }

        if manager.boot_configs.is_empty() {
            tracing::error!(
                "No templates loaded from {} — sandbox creation will fail until templates are built",
                data_dir
            );
        }

        // Mark all previously-active sandboxes as Error — on restart we lose
        // process handles. Operator (or the user via delete) cleans them up.
        manager.reconcile_on_startup().await?;

        Ok(manager)
    }

    /// On startup, every sandbox in `sandbox:active` (Running|Paused) is
    /// orphaned: we don't have its `FirecrackerVm` handle. Mark them all
    /// Error and leave cleanup to the user. Records in other states
    /// (Creating/Error/Terminated) are not touched.
    async fn reconcile_on_startup(&self) -> Result<()> {
        let ids = self.redis.sandbox_active_ids().await?;
        if ids.is_empty() { return Ok(()) }

        let mut orphaned = 0;
        for id in &ids {
            if let Err(e) = self.redis.sandbox_set_state(
                id,
                SandboxState::Error,
                Some("orphaned on sandbox-manager restart; delete to clean up"),
            ).await {
                tracing::warn!("reconcile: failed to mark {} as Error: {}", id, e);
                continue;
            }
            orphaned += 1;
        }
        tracing::info!("reconciled {} sandbox(es): {} marked Error (orphaned)", ids.len(), orphaned);
        Ok(())
    }

    pub async fn create_sandbox(
        &self,
        user_id: String,
        template: Option<String>,
        size: Option<VmSize>,
        enroll_token: Option<String>,
    ) -> Result<Sandbox> {
        let template_name = template.unwrap_or_else(|| "alpine-base".to_string());
        let vm_size = size.unwrap_or_else(|| VmSize::from_str(&self.config.default_size).unwrap_or_default());

        if !self.boot_configs.contains_key(&template_name) {
            anyhow::bail!("unknown template: {template_name}");
        }

        // Quota check
        let active = self.redis.sandbox_user_active_count(&user_id).await?;
        if active >= DEFAULT_USER_LIMIT {
            anyhow::bail!("Maximum concurrent sandboxes reached ({DEFAULT_USER_LIMIT})");
        }

        let mut sandbox = Sandbox::new(user_id, template_name.clone(), vm_size.clone());

        // Persist Creating state immediately so crashes mid-boot are visible.
        // Creating is NOT in sandbox:active by design — it's not reconcilable.
        self.redis.sandbox_put(&sandbox).await?;

        // From here on, any error must mark the sandbox Error so we don't
        // leak a Creating record.
        let network = match self.network.allocate(&sandbox.id) {
            Ok(n) => n,
            Err(e) => { self.fail_sandbox(&mut sandbox, format!("network allocate: {e}")).await; return Ok(sandbox); }
        };
        sandbox.ip_address = Some(network.guest_ip);
        sandbox.tap_device = Some(network.tap_name.clone());
        if let Err(e) = self.network.create_tap(&network) {
            self.fail_sandbox(&mut sandbox, format!("create_tap: {e}")).await;
            return Ok(sandbox);
        }

        let boot_config = self.boot_configs.get(&template_name)
            .map(|c| c.clone()).unwrap_or_default();
        let start = std::time::Instant::now();

        match self.launcher.boot(&sandbox.id, &boot_config, &vm_size, &network, enroll_token.as_deref()).await {
            Ok(vm) => {
                tracing::info!("Booted VM {} in {:?} (size: {:?})", sandbox.id, start.elapsed(), vm_size);
                sandbox.pid = Some(vm.pid());
                sandbox.state = SandboxState::Running;
                self.vms.insert(sandbox.id.clone(), Arc::new(RwLock::new(vm)));
            }
            Err(e) => {
                tracing::error!("Failed to boot VM {}: {}", sandbox.id, e);
                sandbox.state = SandboxState::Error;
                sandbox.error = Some(e.to_string());
                if let Some(ref tap) = sandbox.tap_device {
                    self.network.destroy_tap(tap).ok();
                }
            }
        }

        self.redis.sandbox_put(&sandbox).await?;
        if sandbox.state == SandboxState::Running {
            self.redis.sandbox_inc_created().await.ok();
        }
        Ok(sandbox)
    }

    /// Mark a sandbox Error and persist. Used on mid-boot failures.
    async fn fail_sandbox(&self, sandbox: &mut Sandbox, reason: String) {
        tracing::error!("sandbox {}: {}", sandbox.id, reason);
        sandbox.state = SandboxState::Error;
        sandbox.error = Some(reason);
        if let Some(ref tap) = sandbox.tap_device {
            self.network.destroy_tap(tap).ok();
        }
        self.redis.sandbox_put(sandbox).await.ok();
    }

    pub async fn get_sandbox(&self, id: &str) -> Result<Option<Sandbox>> {
        self.redis.sandbox_get(id).await
    }

    pub async fn list_sandboxes(&self, user_id: Option<&str>) -> Result<Vec<Sandbox>> {
        self.redis.sandbox_list(user_id).await
    }

    pub async fn delete_sandbox(&self, id: &str) -> Result<()> {
        let sandbox = self.redis.sandbox_get(id).await?
            .context("Sandbox not found")?;

        // Kill VM process if we have its handle
        if let Some((_, vm)) = self.vms.remove(id) {
            let mut vm = vm.write().await;
            vm.kill().ok();
        } else if let Some(pid) = sandbox.pid {
            // Orphaned from a previous run — best-effort SIGKILL
            unsafe { libc::kill(pid as i32, libc::SIGKILL); }
        }

        if let Some(tap) = sandbox.tap_device {
            self.network.destroy_tap(&tap).ok();
        }

        self.redis.sandbox_delete(id).await?;
        tracing::info!("Deleted sandbox {}", id);
        Ok(())
    }

    pub async fn pause_sandbox(&self, id: &str) -> Result<()> {
        let sandbox = self.redis.sandbox_get(id).await?
            .context("Sandbox not found")?;
        if sandbox.state != SandboxState::Running {
            anyhow::bail!("Sandbox is not running");
        }
        let vm_ref = self.vms.get(id)
            .context("VM process handle lost (orphaned); delete and recreate")?;
        vm_ref.read().await.pause().await?;
        self.redis.sandbox_set_state(id, SandboxState::Paused, None).await?;
        tracing::info!("Paused sandbox {}", id);
        Ok(())
    }

    pub async fn resume_sandbox(&self, id: &str) -> Result<()> {
        let sandbox = self.redis.sandbox_get(id).await?
            .context("Sandbox not found")?;
        if sandbox.state != SandboxState::Paused {
            anyhow::bail!("Sandbox is not paused");
        }
        let vm_ref = self.vms.get(id)
            .context("VM process handle lost (orphaned); delete and recreate")?;
        vm_ref.read().await.resume().await?;
        self.redis.sandbox_set_state(id, SandboxState::Running, None).await?;
        tracing::info!("Resumed sandbox {}", id);
        Ok(())
    }

    /// Ask the guest to give back `target_mib` of RAM via virtio-balloon.
    /// Set to 0 to deflate fully. Requires CONFIG_VIRTIO_BALLOON in the guest.
    pub async fn balloon_sandbox(&self, id: &str, target_mib: u32) -> Result<()> {
        let _ = self.redis.sandbox_get(id).await?
            .context("Sandbox not found")?;
        let vm_ref = self.vms.get(id)
            .context("VM process handle lost (orphaned); delete and recreate")?;
        vm_ref.read().await.balloon_set(target_mib).await?;
        tracing::info!("Ballooned sandbox {} to {} MiB", id, target_mib);
        Ok(())
    }

    pub async fn stats(&self) -> Result<SandboxStats> {
        let mut stats = SandboxStats {
            total_created: self.redis.sandbox_total_created().await.unwrap_or(0),
            active: 0,
            running: 0,
            paused: 0,
            total_memory_mb: 0,
            actual_memory_kb: 0,
        };
        for sandbox in self.redis.sandbox_list(None).await? {
            if sandbox.is_active() {
                stats.active += 1;
                stats.total_memory_mb += sandbox.size.memory_mb();
                stats.actual_memory_kb += sandbox.size.estimated_actual_memory_kb() as u64;
            }
            if sandbox.state == SandboxState::Running { stats.running += 1; }
            if sandbox.state == SandboxState::Paused { stats.paused += 1; }
        }
        Ok(stats)
    }

    pub async fn load_template(&self, name: &str, config: &TemplateConfig) -> Result<()> {
        let template_dir = self.config.templates_dir.join(name);
        let boot_config = BootConfig {
            kernel_path: template_dir.join(&config.kernel_path),
            rootfs_path: template_dir.join(&config.rootfs_path),
            boot_args: config.boot_args.clone(),
        };
        if !boot_config.kernel_path.exists() {
            anyhow::bail!("Kernel not found: {:?}", boot_config.kernel_path);
        }
        if !boot_config.rootfs_path.exists() {
            anyhow::bail!("Rootfs not found: {:?}", boot_config.rootfs_path);
        }
        self.boot_configs.insert(name.to_string(), boot_config);
        tracing::info!("Loaded template: {}", name);
        Ok(())
    }

    pub fn list_templates(&self) -> Vec<String> {
        self.boot_configs.iter().map(|t| t.key().clone()).collect()
    }

    /// Cleanup sandboxes idle longer than `max_idle_seconds`.
    pub async fn cleanup_idle(&self, max_idle_seconds: u64) -> usize {
        let sandboxes = match self.redis.sandbox_list(None).await {
            Ok(s) => s,
            Err(e) => { tracing::warn!("cleanup_idle: list failed: {}", e); return 0; }
        };
        let to_remove: Vec<String> = sandboxes.into_iter()
            .filter(|s| s.state == SandboxState::Running && s.idle_seconds() > max_idle_seconds)
            .map(|s| s.id)
            .collect();
        let mut cleaned = 0;
        for id in to_remove {
            if self.delete_sandbox(&id).await.is_ok() { cleaned += 1; }
        }
        if cleaned > 0 { tracing::info!("Cleaned up {} idle sandboxes", cleaned); }
        cleaned
    }
}
