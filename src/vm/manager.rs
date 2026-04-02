//! VM Manager - orchestrates VM lifecycle using Firecracker processes

use anyhow::{Context, Result};
use dashmap::DashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::config::{ManagerConfig, TemplateConfig};
use super::firecracker::{BootConfig, FirecrackerLauncher, FirecrackerVm};
use super::network::NetworkManager;
use super::session::{Session, SessionState, SessionStats};
use super::size::VmSize;

/// VM Manager handles all VM operations
pub struct VmManager {
    /// Configuration
    config: ManagerConfig,

    /// Firecracker launcher
    launcher: Option<FirecrackerLauncher>,

    /// Network manager
    network: NetworkManager,

    /// Active sessions
    sessions: DashMap<String, Session>,

    /// Running Firecracker VMs
    vms: DashMap<String, Arc<RwLock<FirecrackerVm>>>,

    /// Boot configurations per template
    boot_configs: DashMap<String, BootConfig>,
}

impl VmManager {
    /// Create a new VM manager
    pub async fn new(config: ManagerConfig) -> Result<Self> {
        // Initialize Firecracker launcher
        let launcher = if config.enable_kvm {
            let runtime_dir = config.overlays_dir.join("runtime");
            match FirecrackerLauncher::new(runtime_dir) {
                Ok(l) => {
                    tracing::info!("Firecracker launcher initialized");
                    Some(l)
                }
                Err(e) => {
                    tracing::warn!("Firecracker not available: {}. Running in mock mode.", e);
                    None
                }
            }
        } else {
            tracing::info!("KVM disabled, running in mock mode");
            None
        };

        // Initialize network
        let network = NetworkManager::new(&config.bridge_name, &config.network_subnet)?;

        // Initialize bridge (requires root)
        if let Err(e) = network.init_bridge() {
            tracing::warn!(
                "Failed to initialize bridge: {}. Networking may not work.",
                e
            );
        }

        // Create directories
        tokio::fs::create_dir_all(&config.templates_dir).await.ok();
        tokio::fs::create_dir_all(&config.overlays_dir).await.ok();
        tokio::fs::create_dir_all(&config.snapshots_dir).await.ok();
        tokio::fs::create_dir_all(config.overlays_dir.join("runtime"))
            .await
            .ok();

        let manager = Self {
            config,
            launcher,
            network,
            sessions: DashMap::new(),
            vms: DashMap::new(),
            boot_configs: DashMap::new(),
        };

        // Load default template configs
        let default_config = BootConfig::default();
        manager.boot_configs.insert("alpine-base".to_string(), default_config.clone());
        
        // Alpine-edge template (with zig-edge agent)
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        let data_dir = std::env::var("DATA_DIR")
            .unwrap_or_else(|_| format!("{}/sandbox-data", home));
        let edge_config = BootConfig {
            kernel_path: std::path::PathBuf::from(format!("{}/templates/alpine-edge/vmlinux", data_dir)),
            rootfs_path: std::path::PathBuf::from(format!("{}/templates/alpine-edge/rootfs.ext4", data_dir)),
            boot_args: "console=ttyS0 reboot=k panic=1 pci=off init=/init".into(),
        };
        if edge_config.kernel_path.exists() && edge_config.rootfs_path.exists() {
            manager.boot_configs.insert("alpine-edge".to_string(), edge_config);
            tracing::info!("Loaded alpine-edge template");
        }

        Ok(manager)
    }

    /// Create a new sandbox
    pub async fn create_sandbox(
        &self,
        user_id: String,
        template: Option<String>,
        size: Option<VmSize>,
        edge_token: Option<String>,
    ) -> Result<Session> {
        let template_name = template.unwrap_or_else(|| "alpine-base".to_string());
        let vm_size = size.unwrap_or_else(|| {
            VmSize::from_str(&self.config.default_size).unwrap_or_default()
        });

        // Check limits
        let active_count = self
            .sessions
            .iter()
            .filter(|s| s.user_id == user_id && s.is_active())
            .count();
        if active_count >= 10 {
            anyhow::bail!("Maximum concurrent sandboxes reached");
        }

        // Create session
        let mut session = Session::new(user_id, template_name.clone(), vm_size.clone());

        // Allocate network
        let network = self.network.allocate(&session.id)?;
        session.ip_address = Some(network.guest_ip);
        session.tap_device = Some(network.tap_name.clone());

        // Create TAP device
        self.network.create_tap(&network)?;

        // Boot Firecracker VM
        if let Some(ref launcher) = self.launcher {
            let boot_config = self
                .boot_configs
                .get(&template_name)
                .map(|c| c.clone())
                .unwrap_or_default();

            let start = std::time::Instant::now();

            match launcher.boot(&session.id, &boot_config, &vm_size, &network, edge_token.as_deref()).await {
                Ok(vm) => {
                    let elapsed = start.elapsed();
                    tracing::info!(
                        "Booted VM {} in {:?} (size: {:?})",
                        session.id,
                        elapsed,
                        vm_size
                    );

                    session.pid = Some(vm.pid());
                    session.state = SessionState::Running;

                    self.vms.insert(session.id.clone(), Arc::new(RwLock::new(vm)));
                }
                Err(e) => {
                    tracing::error!("Failed to boot VM {}: {}", session.id, e);
                    session.state = SessionState::Error;
                    session.error = Some(e.to_string());

                    // Cleanup TAP on failure
                    if let Some(ref tap) = session.tap_device {
                        self.network.destroy_tap(tap).ok();
                    }
                }
            }
        } else {
            // Mock mode - just mark as running
            session.state = SessionState::Running;
            tracing::info!("Created mock sandbox {}", session.id);
        }

        // Store session
        let session_clone = session.clone();
        self.sessions.insert(session.id.clone(), session);

        Ok(session_clone)
    }

    /// Get sandbox by ID
    pub fn get_sandbox(&self, id: &str) -> Option<Session> {
        self.sessions.get(id).map(|s| s.clone())
    }

    /// List sandboxes, optionally filtered by user_id
    pub fn list_sandboxes(&self, user_id: Option<&str>) -> Vec<Session> {
        self.sessions
            .iter()
            .filter(|s| user_id.map_or(true, |uid| s.user_id == uid))
            .map(|s| s.clone())
            .collect()
    }

    /// Delete sandbox
    pub async fn delete_sandbox(&self, id: &str) -> Result<()> {
        // Get session
        let session = self
            .sessions
            .remove(id)
            .map(|(_, s)| s)
            .context("Sandbox not found")?;

        // Kill VM
        if let Some((_, vm)) = self.vms.remove(id) {
            let mut vm = vm.write().await;
            vm.kill().ok();
        }

        // Cleanup TAP device
        if let Some(tap) = session.tap_device {
            self.network.destroy_tap(&tap)?;
        }

        tracing::info!("Deleted sandbox {}", id);

        Ok(())
    }

    /// Pause a sandbox
    pub async fn pause_sandbox(&self, id: &str) -> Result<()> {
        let mut session = self.sessions.get_mut(id).context("Sandbox not found")?;

        if session.state != SessionState::Running {
            anyhow::bail!("Sandbox is not running");
        }

        if let Some(vm_ref) = self.vms.get(id) {
            let vm = vm_ref.read().await;
            vm.pause().await?;
        }

        session.state = SessionState::Paused;
        tracing::info!("Paused sandbox {}", id);

        Ok(())
    }

    /// Resume a paused sandbox
    pub async fn resume_sandbox(&self, id: &str) -> Result<()> {
        let mut session = self.sessions.get_mut(id).context("Sandbox not found")?;

        if session.state != SessionState::Paused {
            anyhow::bail!("Sandbox is not paused");
        }

        if let Some(vm_ref) = self.vms.get(id) {
            let vm = vm_ref.read().await;
            vm.resume().await?;
        }

        session.state = SessionState::Running;
        session.touch();
        tracing::info!("Resumed sandbox {}", id);

        Ok(())
    }

    /// Get statistics
    pub fn stats(&self) -> SessionStats {
        let mut stats = SessionStats {
            total_created: 0,
            active: 0,
            running: 0,
            paused: 0,
            total_memory_mb: 0,
            actual_memory_kb: 0,
        };

        for session in self.sessions.iter() {
            if session.is_active() {
                stats.active += 1;
                stats.total_memory_mb += session.size.memory_mb();
                stats.actual_memory_kb += session.size.estimated_actual_memory_kb() as u64;
            }
            if session.state == SessionState::Running {
                stats.running += 1;
            }
            if session.state == SessionState::Paused {
                stats.paused += 1;
            }
        }

        stats
    }

    /// Load a template from disk
    pub async fn load_template(&self, name: &str, config: &TemplateConfig) -> Result<()> {
        let template_dir = self.config.templates_dir.join(name);

        let boot_config = BootConfig {
            kernel_path: template_dir.join(&config.kernel_path),
            rootfs_path: template_dir.join(&config.rootfs_path),
            boot_args: config.boot_args.clone(),
        };

        // Verify files exist
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

    /// List registered templates
    pub fn list_templates(&self) -> Vec<String> {
        self.boot_configs.iter().map(|t| t.key().clone()).collect()
    }

    /// Cleanup idle sandboxes
    pub async fn cleanup_idle(&self, max_idle_seconds: u64) -> usize {
        let mut cleaned = 0;
        let to_remove: Vec<String> = self
            .sessions
            .iter()
            .filter(|s| s.state == SessionState::Running && s.idle_seconds() > max_idle_seconds)
            .map(|s| s.id.clone())
            .collect();

        for id in to_remove {
            if self.delete_sandbox(&id).await.is_ok() {
                cleaned += 1;
            }
        }

        if cleaned > 0 {
            tracing::info!("Cleaned up {} idle sandboxes", cleaned);
        }

        cleaned
    }

}
