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
use super::lite::{ExecOutput, LiteBackend, LiteTemplate};
use super::network::NetworkManager;
use super::sandbox::{Sandbox, SandboxKind, SandboxState, SandboxStats};
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
    /// Static Firecracker template registry
    boot_configs: DashMap<String, BootConfig>,
    /// Lite (bwrap) backend + its templates
    lite: LiteBackend,
    lite_templates: DashMap<String, LiteTemplate>,
}

impl VmManager {
    pub async fn new(config: ManagerConfig, redis: RedisClient) -> Result<Self> {
        let runtime_dir = config.overlays_dir.join("runtime");
        let launcher = FirecrackerLauncher::new(runtime_dir)
            .context("Firecracker launcher init failed (need /dev/kvm + firecracker binary)")?;
        tracing::info!("Firecracker launcher initialized");

        let network = NetworkManager::new(&config.bridge_name, &config.network_subnet)?;
        network.init_bridge()
            .context("bridge init failed — is sandbox-bridge.service running? (sudo systemctl status sandbox-bridge)")?;

        tokio::fs::create_dir_all(&config.templates_dir).await.ok();
        tokio::fs::create_dir_all(&config.overlays_dir).await.ok();
        tokio::fs::create_dir_all(&config.snapshots_dir).await.ok();
        // Probe reflink support: at 1000 VMs, ext4 fallback (real copies) blows up disk.
        let probe = config.overlays_dir.join(".reflink-probe");
        let _ = tokio::fs::write(&probe, b"x").await;
        let supports_reflink = tokio::process::Command::new("cp").args(["--reflink=always"]).arg(&probe).arg(probe.with_extension("c")).status().await.map(|s| s.success()).unwrap_or(false);
        let _ = tokio::fs::remove_file(&probe).await; let _ = tokio::fs::remove_file(probe.with_extension("c")).await;
        if !supports_reflink { tracing::warn!("overlays_dir {} is on a filesystem without reflink — VM rootfs clones will be real copies. Use xfs(reflink=1) or btrfs to scale to 1000+ VMs.", config.overlays_dir.display()); }
        tokio::fs::create_dir_all(config.overlays_dir.join("runtime")).await.ok();
        let lite_scratch = config.overlays_dir.join("lite");
        tokio::fs::create_dir_all(&lite_scratch).await.ok();

        let manager = Self {
            config,
            launcher,
            network,
            redis,
            vms: DashMap::new(),
            boot_configs: DashMap::new(),
            lite: LiteBackend::new(lite_scratch),
            lite_templates: DashMap::new(),
        };

        // Auto-discover templates from `config.templates_dir` (TEMPLATES_DIR env):
        //   <templates_dir>/<name>/{vmlinux,rootfs.ext4}  → Firecracker VM
        //   <templates_dir>/<name>/rootfs/                → bwrap (lite)
        manager.discover_templates().await;

        if manager.boot_configs.is_empty() && manager.lite_templates.is_empty() {
            tracing::error!(
                "No templates discovered in {} — sandbox creation will fail until at least one is built",
                manager.config.templates_dir.display()
            );
        }

        // Mark all previously-active sandboxes as Error — on restart we lose
        // process handles. Operator (or the user via delete) cleans them up.
        manager.reconcile_on_startup().await?;

        Ok(manager)
    }

    /// On startup, every active *VM* sandbox is orphaned (we lost the
    /// Firecracker process handle) — mark those Error. Lite sandboxes
    /// have no process to lose; their state lives entirely in Redis +
    /// a scratch dir on disk, so they survive restart untouched.
    async fn reconcile_on_startup(&self) -> Result<()> {
        let ids = self.redis.sandbox_active_ids().await?;
        if ids.is_empty() { return Ok(()) }

        let (mut orphaned, mut preserved) = (0, 0);
        for id in &ids {
            let sandbox = match self.redis.sandbox_get(id).await {
                Ok(Some(s)) => s,
                Ok(None) => continue,
                Err(e) => { tracing::warn!("reconcile: get {} failed: {}", id, e); continue; }
            };
            if sandbox.kind == SandboxKind::Lite { preserved += 1; continue; }
            // VM sandbox: previous firecracker is gone (we lost the Child handle on
            // restart). Destroy its persistent TAP so it doesn't accumulate on the
            // bridge across restarts.
            if let Some(ref tap) = sandbox.tap_device {
                if let Err(ce) = self.network.destroy_tap(tap) {
                    tracing::warn!("reconcile: destroy_tap({}) failed: {:#}", tap, ce);
                }
            }
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
        tracing::info!("reconciled {} sandbox(es): {} VM marked Error, {} lite preserved", ids.len(), orphaned, preserved);
        Ok(())
    }

    pub async fn create_sandbox(
        &self,
        user_id: String,
        template_name: String,
        size: Option<VmSize>,
        enroll_token: Option<String>,
    ) -> Result<Sandbox> {
        self.create_sandbox_with_id(crate::vm::sandbox::generate_sandbox_id(), user_id, template_name, size, enroll_token).await
    }

    /// Same as `create_sandbox`, but the caller provides the sandbox id ahead
    /// of time. Used so the id can be stamped onto the bridge enroll token
    /// before the VM is booted (enables device-row cleanup on sandbox delete).
    pub async fn create_sandbox_with_id(
        &self,
        sandbox_id: String,
        user_id: String,
        template_name: String,
        size: Option<VmSize>,
        enroll_token: Option<String>,
    ) -> Result<Sandbox> {
        let kind = self.template_kind(&template_name)
            .with_context(|| format!("unknown template: {template_name}"))?;
        let vm_size = size.unwrap_or_else(|| VmSize::from_str(&self.config.default_size).unwrap_or_default());

        // Quota check
        let active = self.redis.sandbox_user_active_count(&user_id).await?;
        if active >= DEFAULT_USER_LIMIT {
            anyhow::bail!("Maximum concurrent sandboxes reached ({DEFAULT_USER_LIMIT})");
        }

        if kind == SandboxKind::Lite {
            let mut sandbox = Sandbox::new_with_id(sandbox_id, user_id, template_name, vm_size, SandboxKind::Lite);
            // Lite is "running" in the sense that exec is allowed against it;
            // there's no actual long-running process. State persists in /work.
            self.redis.sandbox_put(&sandbox).await?;
            if let Err(e) = self.lite.provision(&sandbox.id).await {
                self.fail_sandbox(&mut sandbox, format!("lite provision: {e}")).await;
                return Ok(sandbox);
            }
            sandbox.state = SandboxState::Running;
            self.redis.sandbox_put(&sandbox).await?;
            self.redis.sandbox_inc_created().await.ok();
            return Ok(sandbox);
        }

        let mut sandbox = Sandbox::new_with_id(sandbox_id, user_id, template_name.clone(), vm_size.clone(), SandboxKind::Vm);

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
        if let Err(e) = self.network.create_tap(&network) {
            // create_tap is transactional: it has already rolled back any persistent TAP.
            // Don't set tap_device, so fail_sandbox won't try to destroy it again.
            self.fail_sandbox(&mut sandbox, format!("create_tap: {e}")).await;
            return Ok(sandbox);
        }
        sandbox.tap_device = Some(network.tap_name.clone());

        let template_boot = self.boot_configs.get(&template_name)
            .map(|c| c.clone()).unwrap_or_default();

        // Clone the template rootfs into a per-sandbox file so concurrent VMs
        // don't share a writable ext4 (would corrupt each other's creds).
        // `--reflink=auto` is metadata-only on xfs(reflink=1)/btrfs (~ms, ~0 disk);
        // falls back to a real copy on ext4 etc — `--sparse=always` keeps that
        // copy thin. Host should be xfs+reflink=1 or btrfs to scale to 1k+ VMs.
        let overlay_dir = self.config.overlays_dir.join("rootfs").join(&sandbox.id);
        if let Err(e) = tokio::fs::create_dir_all(&overlay_dir).await {
            self.fail_sandbox(&mut sandbox, format!("overlay dir: {e}")).await;
            return Ok(sandbox);
        }
        let overlay_rootfs = overlay_dir.join("rootfs.ext4");
        let cp_status = tokio::process::Command::new("cp")
            .args(["--reflink=auto", "--sparse=always"])
            .arg(&template_boot.rootfs_path)
            .arg(&overlay_rootfs)
            .status().await;
        match cp_status {
            Ok(s) if s.success() => {}
            Ok(s) => {
                tokio::fs::remove_dir_all(&overlay_dir).await.ok();
                self.fail_sandbox(&mut sandbox, format!("rootfs clone: cp exited {s}")).await;
                return Ok(sandbox);
            }
            Err(e) => {
                tokio::fs::remove_dir_all(&overlay_dir).await.ok();
                self.fail_sandbox(&mut sandbox, format!("rootfs clone: {e}")).await;
                return Ok(sandbox);
            }
        }
        sandbox.rootfs_overlay = Some(overlay_rootfs.clone());

        let boot_config = BootConfig { rootfs_path: overlay_rootfs, ..template_boot };
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
                    if let Err(ce) = self.network.destroy_tap(tap) {
                        tracing::warn!("destroy_tap({}) failed: {:#}", tap, ce);
                    }
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
            if let Err(ce) = self.network.destroy_tap(tap) {
                tracing::warn!("destroy_tap({}) failed: {:#}", tap, ce);
            }
        }
        if let Some(ref p) = sandbox.rootfs_overlay {
            if let Some(dir) = p.parent() {
                tokio::fs::remove_dir_all(dir).await.ok();
            }
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

        if sandbox.kind == SandboxKind::Lite {
            self.lite.destroy(id).await;
            self.redis.sandbox_delete(id).await?;
            tracing::info!("Deleted lite sandbox {}", id);
            return Ok(());
        }

        // Kill VM process if we have its handle
        if let Some((_, vm)) = self.vms.remove(id) {
            let mut vm = vm.write().await;
            vm.kill().ok();
        } else if let Some(pid) = sandbox.pid {
            // Orphaned from a previous run — best-effort SIGKILL
            unsafe { libc::kill(pid as i32, libc::SIGKILL); }
        }

        if let Some(tap) = sandbox.tap_device {
            if let Err(ce) = self.network.destroy_tap(&tap) {
                tracing::warn!("destroy_tap({}) failed: {:#}", tap, ce);
            }
        }

        if let Some(p) = sandbox.rootfs_overlay {
            if let Some(dir) = p.parent() {
                if let Err(e) = tokio::fs::remove_dir_all(dir).await {
                    tracing::warn!("remove rootfs overlay {}: {}", dir.display(), e);
                }
            }
        }

        self.redis.sandbox_delete(id).await?;
        tracing::info!("Deleted sandbox {}", id);
        Ok(())
    }

    /// Run `argv` in a lite sandbox. Errors if the sandbox is a Vm.
    pub async fn exec_lite(&self, id: &str, argv: &[String]) -> Result<ExecOutput> {
        let sandbox = self.redis.sandbox_get(id).await?
            .context("Sandbox not found")?;
        if sandbox.kind != SandboxKind::Lite {
            anyhow::bail!("exec is only supported on lite sandboxes; use the bridge for VMs");
        }
        let template = self.lite_templates.get(&sandbox.template)
            .with_context(|| format!("lite template missing: {}", sandbox.template))?
            .clone();
        let out = self.lite.exec(id, &template, argv).await?;
        // Touch last_activity so cleanup_idle works for lite sandboxes too.
        if let Ok(Some(mut s)) = self.redis.sandbox_get(id).await {
            s.touch();
            self.redis.sandbox_put(&s).await.ok();
        }
        Ok(out)
    }

    pub async fn pause_sandbox(&self, id: &str) -> Result<()> {
        let sandbox = self.redis.sandbox_get(id).await?
            .context("Sandbox not found")?;
        if sandbox.kind == SandboxKind::Lite {
            anyhow::bail!("pause is not supported on lite sandboxes");
        }
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
        if sandbox.kind == SandboxKind::Lite {
            anyhow::bail!("resume is not supported on lite sandboxes");
        }
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
        let sandbox = self.redis.sandbox_get(id).await?
            .context("Sandbox not found")?;
        if sandbox.kind == SandboxKind::Lite {
            anyhow::bail!("balloon is not supported on lite sandboxes");
        }
        let vm_ref = self.vms.get(id)
            .context("VM process handle lost (orphaned); delete and recreate")?;
        vm_ref.read().await.balloon_set(target_mib).await?;
        tracing::info!("Ballooned sandbox {} to {} MiB", id, target_mib);
        Ok(())
    }

    /// Look up which backend a template uses. Errors if the template is unknown.
    pub fn template_kind(&self, name: &str) -> Result<SandboxKind> {
        if self.boot_configs.contains_key(name) { return Ok(SandboxKind::Vm); }
        if self.lite_templates.contains_key(name) { return Ok(SandboxKind::Lite); }
        anyhow::bail!("unknown template: {name}")
    }

    /// Walk `config.templates_dir/*` and register every discoverable template.
    /// VM template:   contains `vmlinux` + `rootfs.ext4`.
    /// Lite template: contains a `rootfs/` directory (used as bwrap root).
    /// `allowed-bins.txt` next to a lite rootfs (one binary per line) restricts
    /// what callers may exec; missing file means no restriction beyond PATH.
    async fn discover_templates(&self) {
        let templates_dir = &self.config.templates_dir;
        let mut entries = match tokio::fs::read_dir(templates_dir).await {
            Ok(e) => e,
            Err(e) => { tracing::warn!("templates dir {templates_dir:?} unreadable: {e}"); return; }
        };
        while let Ok(Some(entry)) = entries.next_entry().await {
            let dir = entry.path();
            let Some(name) = dir.file_name().and_then(|n| n.to_str()).map(str::to_owned) else { continue };

            let kernel = dir.join("vmlinux");
            let rootfs_ext4 = dir.join("rootfs.ext4");
            let lite_rootfs = dir.join("rootfs");

            if kernel.is_file() && rootfs_ext4.is_file() {
                self.boot_configs.insert(name.clone(), BootConfig {
                    kernel_path: kernel,
                    rootfs_path: rootfs_ext4,
                    boot_args: "console=ttyS0 reboot=k panic=1 pci=off init=/init".into(),
                });
                tracing::info!("template '{name}' (vm) loaded");
            } else if lite_rootfs.is_dir() {
                let allowed_bins = tokio::fs::read_to_string(dir.join("allowed-bins.txt")).await
                    .ok()
                    .map(|s| s.lines().map(|l| l.trim().to_string()).filter(|l| !l.is_empty() && !l.starts_with('#')).collect())
                    .unwrap_or_default();
                self.lite_templates.insert(name.clone(), LiteTemplate {
                    rootfs_dir: lite_rootfs,
                    allowed_bins,
                });
                tracing::info!("template '{name}' (lite) loaded");
            }
        }
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
        let mut out: Vec<String> = self.boot_configs.iter().map(|t| t.key().clone()).collect();
        out.extend(self.lite_templates.iter().map(|t| t.key().clone()));
        out
    }
}
