//! VM Manager — thin orchestration layer over Firecracker.
//!
//! VMs are spawned detached (`setsid`) and reparented to PID 1; the manager
//! never owns their `Child` handle. All control happens via API socket on
//! disk. Manager restart, crash, or redeploy leaves running VMs untouched —
//! `reconcile_on_startup` re-attaches them by pid + socket lookup.
//!
//! State split:
//! - Redis (`sandbox:*`): sandbox inventory. Source of truth, includes pid.
//! - In-memory `vms` DashMap: lightweight [`FirecrackerVm`] handles
//!   (pid + socket path), rebuilt on startup from Redis.
//! - In-memory `boot_configs`: static template registry, loaded at startup.

use anyhow::{Context, Result};
use dashmap::DashMap;

use super::config::{ManagerConfig, TemplateConfig};
use super::firecracker::{read_proc_starttime, BootConfig, FirecrackerLauncher, FirecrackerVm};
use super::lite::{ExecBinds, ExecOutput, LiteBackend, LiteTemplate};
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
    /// Live VM handles. Each is just `{pid, socket_path}` — cheap to construct,
    /// no kernel resources. Rebuilt from Redis on startup via re-attach.
    vms: DashMap<String, FirecrackerVm>,
    /// Static Firecracker template registry
    boot_configs: DashMap<String, BootConfig>,
    /// Lite (bwrap) backend + its templates
    lite: LiteBackend,
    lite_templates: DashMap<String, LiteTemplate>,
}

impl VmManager {
    pub fn runtime_dir(&self) -> std::path::PathBuf {
        self.config.overlays_dir.join("runtime")
    }

    /// Host UDS that maps to the VM's virtio-vsock device. Used by clients
    /// (SSH ProxyCommand `fc-vsock-proxy`) to reach guest vsock ports.
    pub fn vsock_path_for(&self, id: &str) -> std::path::PathBuf {
        self.launcher.vsock_path_for(id)
    }

    pub async fn new(config: ManagerConfig, redis: RedisClient) -> Result<Self> {
        let runtime_dir = config.overlays_dir.join("runtime");
        let launcher = FirecrackerLauncher::new(runtime_dir)
            .context("Firecracker launcher init failed (need /dev/kvm + firecracker binary)")?;
        tracing::info!("Firecracker launcher initialized");

        let network = NetworkManager::new(&config.bridge_name, &config.network_subnet, redis.clone())?;
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

    /// On startup, re-attach to every still-running Firecracker. Because VMs
    /// are spawned detached (`setsid` + dropped Child), they survive manager
    /// restarts. Re-attach requires:
    ///   1. `pid` + `pid_starttime` recorded in Redis
    ///   2. `/proc/<pid>/stat` start_time still matches (defends vs PID reuse)
    ///   3. the API socket responds to a probe request (defends vs stale
    ///      socket file from a crashed FC whose pid was reused)
    /// Anything else → Error + tear down TAP/IP claim.
    async fn reconcile_on_startup(&self) -> Result<()> {
        let ids = self.redis.sandbox_active_ids().await?;
        if ids.is_empty() { return Ok(()) }

        let (mut reattached, mut dead, mut lite) = (0, 0, 0);
        for id in &ids {
            let sandbox = match self.redis.sandbox_get(id).await {
                Ok(Some(s)) => s,
                Ok(None) => continue,
                Err(e) => { tracing::warn!("reconcile: get {} failed: {}", id, e); continue; }
            };
            if sandbox.kind == SandboxKind::Lite { lite += 1; continue; }

            let socket_path = self.launcher.socket_path_for(id);
            // Old records (pre-pid_starttime) have only `pid`. Backfill from
            // /proc on first encounter — safe because we additionally require
            // the API socket health probe below to confirm it's actually the
            // Firecracker we expect, not just any process that inherited the
            // pid. Backfilled value is persisted only if reattach succeeds.
            let vm = match (sandbox.pid, sandbox.pid_starttime) {
                (Some(pid), Some(st)) => FirecrackerVm::attach(pid, st, socket_path.clone()),
                (Some(pid), None) => {
                    read_proc_starttime(pid).and_then(|st| {
                        FirecrackerVm::attach(pid, st, socket_path.clone())
                    })
                }
                _ => None,
            };
            // A live attach also requires the API socket to actually answer
            // — a `GET /` round-trip catches stale socket files / wedged FCs.
            // Tight timeout: at startup we want to make a verdict in ms, not
            // wait 2s per orphaned VM.
            let healthy = if let Some(ref v) = vm {
                v.is_alive()
                    && v.api_request_with_timeout("GET", "/", None, std::time::Duration::from_millis(500))
                        .await.is_ok()
            } else { false };

            if let (Some(vm), true) = (vm, healthy) {
                // Re-assert the IP claim only if it's free OR already ours.
                // If a different sandbox owns it, log loudly — there's no
                // safe automatic recovery.
                if let Some(ip) = sandbox.ip_address {
                    self.reassert_ip_claim(ip, id).await;
                }
                // Backfill pid_starttime in Redis if it was missing on an old
                // record. Future reattaches/deletes can then trust it without
                // re-reading /proc.
                if sandbox.pid_starttime != Some(vm.starttime()) {
                    let mut updated = sandbox.clone();
                    updated.pid_starttime = Some(vm.starttime());
                    if let Err(e) = self.redis.sandbox_put(&updated).await {
                        tracing::warn!("reconcile: failed to backfill pid_starttime for {}: {}", id, e);
                    }
                }
                self.vms.insert(id.clone(), vm);
                reattached += 1;
                continue;
            }

            // Process is gone (or pid reused, or socket dead). Tear down
            // network slot and mark Error so the owner can delete + recreate.
            if let Some(ref tap) = sandbox.tap_device {
                if let Err(ce) = self.network.destroy_tap(tap) {
                    tracing::warn!("reconcile: destroy_tap({}) failed: {:#}", tap, ce);
                }
            }
            if let Some(ip) = sandbox.ip_address {
                self.release_ip_if_owner(ip, id).await;
            }
            // Stale socket file from a crashed FC.
            std::fs::remove_file(&socket_path).ok();
            if let Err(e) = self.redis.sandbox_set_state(
                id,
                SandboxState::Error,
                Some("Firecracker process gone (crashed or host rebooted)"),
            ).await {
                tracing::warn!("reconcile: failed to mark {} as Error: {}", id, e);
                continue;
            }
            dead += 1;
        }
        tracing::info!(
            "reconciled {} sandbox(es): {} VM re-attached, {} VM dead → Error, {} lite preserved",
            ids.len(), reattached, dead, lite,
        );

        // Sweep stale Creating records — sandboxes whose boot was interrupted
        // (manager crash mid-create_sandbox). They sit outside `sandbox:active`
        // so the loop above didn't see them. Because create_sandbox now
        // checkpoints after each resource acquisition, the record's fields
        // tell us exactly what to release: just feed it through the same
        // teardown path as a normal delete. Then mark Error so the user knows.
        let stale: Vec<_> = self.redis
            .sandbox_list(None).await
            .unwrap_or_default()
            .into_iter()
            .filter(|s| s.state == SandboxState::Creating && s.kind == SandboxKind::Vm)
            .collect();
        for sandbox in &stale {
            tracing::warn!("reconcile: cleaning interrupted Creating sandbox {}", sandbox.id);
            // Best-effort teardown of every resource the record knows about.
            if let Some(ref tap) = sandbox.tap_device {
                if let Err(e) = self.network.destroy_tap(tap) {
                    tracing::warn!("reconcile: destroy_tap({}) failed: {:#}", tap, e);
                }
            }
            if let Some(ip) = sandbox.ip_address {
                self.release_ip_if_owner(ip, &sandbox.id).await;
            }
            if let Some(ref p) = sandbox.rootfs_overlay {
                if let Some(dir) = p.parent() {
                    tokio::fs::remove_dir_all(dir).await.ok();
                }
            }
            // FC may or may not have spawned. If pid recorded, identity-check
            // and SIGKILL via FirecrackerVm::attach (handles pid-reuse).
            if let Some(pid) = sandbox.pid {
                let st = sandbox.pid_starttime.or_else(|| read_proc_starttime(pid));
                let socket = self.launcher.socket_path_for(&sandbox.id);
                if let Some(vm) = st.and_then(|st| FirecrackerVm::attach(pid, st, socket.clone())) {
                    vm.shutdown().await.ok();
                } else {
                    std::fs::remove_file(socket).ok();
                }
            }
            self.redis.sandbox_set_state(
                &sandbox.id,
                SandboxState::Error,
                Some("interrupted during creation; manager restarted"),
            ).await.ok();
        }
        if !stale.is_empty() {
            tracing::warn!("reconciled {} stale Creating sandbox(es) → Error", stale.len());
        }
        Ok(())
    }

    /// Try to re-claim an IP for a sandbox we're reattaching. Three outcomes:
    /// claim succeeded (Redis flush case), already ours (idempotent), or
    /// owned by a different sandbox (data corruption — log loudly, leave the
    /// reattached VM running but its IP unaccounted for in our pool so we
    /// don't double-assign it elsewhere).
    async fn reassert_ip_claim(&self, ip: std::net::Ipv4Addr, id: &str) {
        match self.redis.ip_claim_owner(ip).await {
            Ok(Some(owner)) if owner == id => {} // already ours
            Ok(Some(other)) => tracing::error!(
                "reconcile: sandbox {} expects IP {} but Redis says owner is {}; leaving as-is",
                id, ip, other,
            ),
            Ok(None) => match self.redis.ip_claim(ip, id).await {
                Ok(true) => {}
                Ok(false) => {
                    let now_owner = self.redis.ip_claim_owner(ip).await.ok().flatten();
                    tracing::error!(
                        "reconcile: lost race re-claiming IP {} for sandbox {}; current owner={:?}",
                        ip, id, now_owner,
                    );
                }
                Err(e) => tracing::warn!("reconcile: ip_claim({}, {}) failed: {:#}", ip, id, e),
            },
            Err(e) => tracing::warn!("reconcile: ip_claim_owner({}) failed: {:#}", ip, e),
        }
    }

    /// Owner-checked IP release. Refuses to delete a claim that's been
    /// reassigned to a different sandbox in the meantime.
    async fn release_ip_if_owner(&self, ip: std::net::Ipv4Addr, id: &str) {
        if let Err(e) = self.redis.ip_release_if_owner(ip, id).await {
            tracing::warn!("ip_release_if_owner({}, {}): {:#}", ip, id, e);
        }
    }

    /// Provision a sandbox with a caller-supplied id. The id is generated by
    /// `SandboxService` up front so it can be stamped onto the bridge enroll
    /// token before VM boot — that's what lets the backend cascade-delete the
    /// redeemed Device row when the sandbox is destroyed.
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
        //
        // Persist after each irreversible resource acquisition. Without
        // these checkpoints, a manager crash mid-create leaves a Creating
        // record with no allocated-resource fields → user can't `delete` to
        // clean up because `delete_sandbox` reads those fields to know what
        // to release. Cost is 3 extra Redis writes per create — invisible
        // at our request rate.
        let network = match self.network.allocate(&sandbox.id).await {
            Ok(n) => n,
            Err(e) => { self.fail_sandbox(&mut sandbox, format!("network allocate: {e:#}")).await; return Ok(sandbox); }
        };
        sandbox.ip_address = Some(network.guest_ip);
        self.redis.sandbox_put(&sandbox).await.ok(); // checkpoint: ip claimed

        if let Err(e) = self.network.create_tap(&network) {
            // create_tap is transactional: it has already rolled back any persistent TAP.
            // Don't set tap_device, so fail_sandbox won't try to destroy it again.
            self.fail_sandbox(&mut sandbox, format!("create_tap: {e:#}")).await;
            return Ok(sandbox);
        }
        sandbox.tap_device = Some(network.tap_name.clone());
        self.redis.sandbox_put(&sandbox).await.ok(); // checkpoint: tap created

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
        self.redis.sandbox_put(&sandbox).await.ok(); // checkpoint: rootfs cloned

        let boot_config = BootConfig { rootfs_path: overlay_rootfs, ..template_boot };
        let start = std::time::Instant::now();

        match self.launcher.boot(&sandbox.id, &boot_config, &vm_size, &network, enroll_token.as_deref()).await {
            Ok(vm) => {
                tracing::info!("Booted VM {} in {:?} (size: {:?})", sandbox.id, start.elapsed(), vm_size);
                sandbox.pid = Some(vm.pid());
                sandbox.pid_starttime = Some(vm.starttime());
                sandbox.state = SandboxState::Running;
                self.vms.insert(sandbox.id.clone(), vm);
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
                if let Some(ip) = sandbox.ip_address {
                    self.network.release_ip(ip, &sandbox.id).await.ok();
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
        if let Some(ip) = sandbox.ip_address {
            self.network.release_ip(ip, &sandbox.id).await.ok();
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

        // Stop the VM. Prefer the in-memory handle (already pid-starttime
        // verified). If we don't have one, only SIGKILL if the recorded
        // (pid, starttime) still matches /proc — otherwise we'd be killing
        // an unrelated process that inherited the pid.
        if let Some((_, vm)) = self.vms.remove(id) {
            if let Err(e) = vm.shutdown().await {
                tracing::warn!("shutdown({}) failed: {:#}", id, e);
            }
        } else if let Some(pid) = sandbox.pid {
            // Same backfill rule as reconcile: if the record is pre-starttime,
            // read it from /proc and use that. PID-reuse risk is bounded —
            // we'd need a fresh process to (a) inherit this exact pid AND
            // (b) be running between manager startup and this delete call.
            let starttime = sandbox.pid_starttime.or_else(|| read_proc_starttime(pid));
            let socket = self.launcher.socket_path_for(id);
            match starttime.and_then(|st| FirecrackerVm::attach(pid, st, socket.clone())) {
                Some(vm) => {
                    if let Err(e) = vm.shutdown().await {
                        tracing::warn!("shutdown({}) failed: {:#}", id, e);
                    }
                }
                None => {
                    tracing::info!("delete: pid {} for sandbox {} no longer alive; nothing to kill", pid, id);
                    std::fs::remove_file(socket).ok();
                }
            }
        }

        if let Some(tap) = sandbox.tap_device {
            if let Err(ce) = self.network.destroy_tap(&tap) {
                tracing::warn!("destroy_tap({}) failed: {:#}", tap, ce);
            }
        }
        if let Some(ip) = sandbox.ip_address {
            self.network.release_ip(ip, &sandbox.id).await.ok();
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
    pub async fn exec_lite(&self, id: &str, argv: &[String], binds: &ExecBinds) -> Result<ExecOutput> {
        let sandbox = self.redis.sandbox_get(id).await?
            .context("Sandbox not found")?;
        if sandbox.kind != SandboxKind::Lite {
            anyhow::bail!("exec is only supported on lite sandboxes; use the bridge for VMs");
        }
        let template = self.lite_templates.get(&sandbox.template)
            .with_context(|| format!("lite template missing: {}", sandbox.template))?
            .clone();
        let out = self.lite.exec(id, &template, argv, binds).await?;
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
        let vm = self.vms.get(id)
            .context("VM process handle lost (process gone); delete and recreate")?;
        vm.pause().await?;
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
        let vm = self.vms.get(id)
            .context("VM process handle lost (process gone); delete and recreate")?;
        vm.resume().await?;
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
        let vm = self.vms.get(id)
            .context("VM process handle lost (process gone); delete and recreate")?;
        vm.balloon_set(target_mib).await?;
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
