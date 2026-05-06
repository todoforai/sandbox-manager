//! Firecracker process management
//!
//! `sandbox-manager` is a *thin layer* over Firecracker: it spawns each VM
//! with `setsid()` so the VM lives in its own session/pgroup, then forgets it.
//! Manager restarts (deploy, crash, OOM) leave running VMs untouched; on
//! startup the manager re-attaches by checking `pid` (from Redis) + the
//! on-disk API socket. Lifecycle control (pause/resume/balloon/shutdown)
//! happens entirely over the Unix API socket — no `Child` handle needed.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::time::{timeout, Duration};

use super::network::VmNetwork;
use super::size::VmSize;

/// Handle to a running Firecracker VM. Identifies the process by
/// `(pid, starttime)` so PID reuse across a manager restart cannot fool us.
/// Owns nothing the kernel cares about — safe to drop or reconstruct via
/// [`Self::attach`].
pub struct FirecrackerVm {
    pid: u32,
    /// `/proc/<pid>/stat` field 22 (process start_time, in clock ticks since
    /// boot). Stable for the life of the process; cheapest available identity
    /// check that survives manager restart.
    starttime: u64,
    socket_path: PathBuf,
}

impl FirecrackerVm {
    pub fn pid(&self) -> u32 { self.pid }

    pub fn starttime(&self) -> u64 { self.starttime }

    /// Re-attach to an already-running Firecracker. Returns None if the pid
    /// is gone OR its `/proc/<pid>/stat` start_time doesn't match the one
    /// recorded at spawn (i.e. the kernel reused the pid for a different
    /// process). Caller must additionally verify the API socket responds.
    pub fn attach(pid: u32, expected_starttime: u64, socket_path: PathBuf) -> Option<Self> {
        let actual = read_proc_starttime(pid)?;
        if actual != expected_starttime { return None }
        Some(Self { pid, starttime: actual, socket_path })
    }

    /// True iff the *same* process we spawned is still running and not a
    /// zombie. Defends against:
    ///   - PID reuse: starttime must match the value recorded at spawn.
    ///   - Zombie window: a `Z`-state process is a corpse waiting on
    ///     waitpid; treating it as alive would make `shutdown()` poll for
    ///     5s before SIGKILL'ing an already-dead process.
    /// This is the only safe predicate to gate signals on.
    pub fn is_alive(&self) -> bool {
        match read_proc_stat(self.pid) {
            Some((st, state)) => st == self.starttime && state != 'Z',
            None => false,
        }
    }

    /// Send API request to Firecracker. `pub(crate)` so the manager can use
    /// it as a health probe during startup reconciliation.
    ///
    /// Hard-bounded: a wedged or unresponsive socket cannot stall callers
    /// indefinitely. Default 2s for normal ops; callers can override via
    /// [`Self::api_request_with_timeout`] for latency-sensitive paths
    /// (health probes, shutdown).
    pub(crate) async fn api_request(&self, method: &str, path: &str, body: Option<&str>) -> Result<String> {
        self.api_request_with_timeout(method, path, body, Duration::from_secs(2)).await
    }

    pub(crate) async fn api_request_with_timeout(
        &self, method: &str, path: &str, body: Option<&str>, deadline: Duration,
    ) -> Result<String> {
        timeout(deadline, self.api_request_inner(method, path, body))
            .await
            .with_context(|| format!("Firecracker {method} {path} timed out after {deadline:?}"))?
    }

    async fn api_request_inner(&self, method: &str, path: &str, body: Option<&str>) -> Result<String> {
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

    /// Stop the VM. Sends `SendCtrlAltDel` (which the guest /init must trap
    /// as poweroff — without that it's a reboot signal), waits up to
    /// `GRACEFUL_SHUTDOWN_MS`, then SIGKILLs. `waitpid(WNOHANG)` at the end
    /// avoids zombies if we're still the parent. Idempotent.
    pub async fn shutdown(&self) -> Result<()> {
        const GRACEFUL_SHUTDOWN_MS: u64 = 5_000;
        const POLL_MS: u64 = 50;

        // Tight timeout on the API call: if FC is wedged or unstarted (boot
        // failure path), fall through to SIGKILL fast instead of stalling.
        let _ = self.api_request_with_timeout(
            "PUT", "/actions", Some(r#"{"action_type":"SendCtrlAltDel"}"#),
            Duration::from_millis(500),
        ).await;
        for _ in 0..(GRACEFUL_SHUTDOWN_MS / POLL_MS) {
            if !self.is_alive() { break; }
            tokio::time::sleep(Duration::from_millis(POLL_MS)).await;
        }
        if self.is_alive() {
            unsafe { libc::kill(self.pid as i32, libc::SIGKILL); }
            // Brief wait so /proc state actually clears before we remove the
            // socket — avoids races against a quick re-create with the same id.
            for _ in 0..20 {
                if !self.is_alive() { break; }
                tokio::time::sleep(Duration::from_millis(POLL_MS)).await;
            }
        }
        // Reap if we're still the parent. ECHILD = already PID 1's job — fine.
        unsafe {
            let mut status = 0i32;
            libc::waitpid(self.pid as i32, &mut status, libc::WNOHANG);
        }
        std::fs::remove_file(&self.socket_path).ok();
        // Best-effort vsock UDS cleanup. The path convention is shared with
        // FirecrackerLauncher::vsock_path_for; derive it here from the API
        // socket path (sibling file with .vsock.sock instead of .sock).
        if let Some(stem) = self.socket_path.file_stem().and_then(|s| s.to_str()) {
            if let Some(parent) = self.socket_path.parent() {
                std::fs::remove_file(parent.join(format!("{stem}.vsock.sock"))).ok();
            }
        }
        Ok(())
    }
}

/// Read `/proc/<pid>/stat` field 22 (start_time, in clock ticks since boot).
pub(crate) fn read_proc_starttime(pid: u32) -> Option<u64> {
    read_proc_stat(pid).map(|(st, _)| st)
}

/// Read `(start_time, state)` from `/proc/<pid>/stat`. State is field 3,
/// a single char like `R`/`S`/`Z`/`D`. Returns None if the file is missing
/// or malformed.
fn read_proc_stat(pid: u32) -> Option<(u64, char)> {
    parse_proc_stat(&std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?)
}

/// Parse `(start_time, state)` from a `/proc/<pid>/stat` line. Field 2 is
/// `(comm)` and may itself contain spaces or `)` — split on the LAST `") "`
/// so the comm boundary is unambiguous.
fn parse_proc_stat(raw: &str) -> Option<(u64, char)> {
    let tail = raw.rsplit_once(") ")?.1;
    // After `") "`, the next token is field 3 (state). start_time is field
    // 22, so it's at index 22 - 3 = 19 in this tail.
    let mut tokens = tail.split_ascii_whitespace();
    let state = tokens.next()?.chars().next()?;
    let starttime = tokens.nth(18)?.parse::<u64>().ok()?;
    Some((starttime, state))
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

    /// Path conventions, exposed so the manager can probe for re-attach on
    /// startup without duplicating the format string.
    pub fn socket_path_for(&self, vm_id: &str) -> PathBuf {
        self.runtime_dir.join(format!("{}.sock", vm_id))
    }

    /// Host-side UDS for the VM's virtio-vsock device. SSH ProxyCommand and
    /// any other vsock client connects here; per-port mux is in the FC vsock
    /// protocol (`CONNECT <port>\n` / `OK <peer_port>\n`).
    pub fn vsock_path_for(&self, vm_id: &str) -> PathBuf {
        self.runtime_dir.join(format!("{}.vsock.sock", vm_id))
    }

    /// Boot a new Firecracker VM. The process is detached (`setsid`) and the
    /// `Child` handle is dropped — Firecracker is reparented to PID 1, so it
    /// outlives the manager. Lifecycle from this point is driven via the
    /// returned [`FirecrackerVm`] handle (pid + API socket).
    pub async fn boot(
        &self,
        vm_id: &str,
        boot_config: &BootConfig,
        size: &VmSize,
        network: &VmNetwork,
        enroll_token: Option<&str>,
    ) -> Result<FirecrackerVm> {
        let socket_path = self.socket_path_for(vm_id);
        let console_log = self.runtime_dir.join(format!("{}.console.log", vm_id));
        let fc_log      = self.runtime_dir.join(format!("{}.fc.log", vm_id));

        // Remove stale socket from a previous incarnation of this id.
        std::fs::remove_file(&socket_path).ok();

        // Capture guest serial console (`console=ttyS0` in boot_args -> FC stdout)
        // and Firecracker's own stderr. These are the only on-disk traces of
        // what the guest /init / bridge actually did, so don't drop them.
        let console_out = std::fs::File::create(&console_log)
            .with_context(|| format!("create {}", console_log.display()))?;
        let fc_err = std::fs::File::create(&fc_log)
            .with_context(|| format!("create {}", fc_log.display()))?;

        // Spawn Firecracker detached:
        //   - `setsid()` puts FC in its own session + process group, so signals
        //     sent to the manager's pgroup (e.g. PM2 SIGTERM during deploy) do
        //     NOT cascade to the VM.
        //   - We drop the `Child` (`std::mem::drop` after `id()`), which
        //     reparents FC to PID 1. PID 1 reaps it on exit, so no zombies.
        let mut cmd = Command::new(&self.firecracker_bin);
        cmd.args(["--api-sock", socket_path.to_str().unwrap()])
            .stdin(Stdio::null())
            .stdout(Stdio::from(console_out))
            .stderr(Stdio::from(fc_err));
        unsafe {
            cmd.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = cmd.spawn().context("Failed to spawn Firecracker")?;
        let pid = child.id();
        // Drop the Child: we no longer own the parent-child relationship.
        // FC is now PID 1's responsibility for reaping, ours via pid+socket.
        drop(child);

        tracing::info!("VM {} logs: console={} fc={}", vm_id, console_log.display(), fc_log.display());

        // Wait for socket to be ready
        for _ in 0..50 {
            if socket_path.exists() { break; }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        if !socket_path.exists() {
            // FC failed to come up — make sure we don't leak a half-started pid.
            // We're still the parent here; reap inline so the background
            // reaper has nothing to do for this case.
            unsafe {
                libc::kill(pid as i32, libc::SIGKILL);
                let mut status = 0i32;
                libc::waitpid(pid as i32, &mut status, 0);
            }
            anyhow::bail!("Firecracker socket not created");
        }

        // Capture starttime now, before any chance the pid could be reused.
        // We just spawned this pid and the kernel hasn't reaped it (it's
        // running), so /proc/<pid>/stat must exist.
        let starttime = read_proc_starttime(pid)
            .with_context(|| format!("read /proc/{pid}/stat for starttime"))?;
        let vm = FirecrackerVm { pid, starttime, socket_path };

        // Configure + start. If anything fails, we own the FC process and
        // must tear it down before returning Err — otherwise we leak a
        // detached firecracker into PID 1's lap.
        let setup = async {
            self.configure_vm(&vm, boot_config, size, network, enroll_token, vm_id).await?;
            vm.api_request("PUT", "/actions", Some(r#"{"action_type":"InstanceStart"}"#))
                .await
                .context("Failed to start VM")?;
            Ok::<_, anyhow::Error>(())
        }.await;
        if let Err(e) = setup {
            vm.shutdown().await.ok();
            return Err(e);
        }

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
        // Boot args — network only, no secret material. Netmask is derived
        // from the configured subnet prefix so non-/16 deployments still work.
        let boot_args = format!(
            "{} ip={}::{}:{}::eth0:off",
            boot_config.boot_args, network.guest_ip, network.gateway_ip, network.netmask,
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

        // Virtio-vsock — host↔guest socket plane, independent of the bridge/TAP.
        // Used for the SSH recovery path: even if eth0/bridge/NAT is broken,
        // the agent can reach the guest over /var/run/sandbox/<id>/vsock.sock.
        //
        // Firecracker exposes a single vsock device per VM; multiple guest
        // ports are multiplexed by the host UDS protocol (write `CONNECT <port>\n`,
        // read `OK <peer_port>\n`, then stream). See `fc-vsock-proxy`.
        let vsock_path = self.vsock_path_for(sandbox_id);
        // Stale UDS from a previous incarnation breaks bind; remove first.
        std::fs::remove_file(&vsock_path).ok();
        // CID 3 is the lowest legal guest CID (0=hypervisor, 1=local, 2=host).
        // Per-VM uniqueness comes from the per-VM UDS path, not the CID.
        let vsock = serde_json::json!({
            "vsock_id": "vsock0",
            "guest_cid": 3,
            "uds_path": vsock_path,
        });
        if let Err(e) = vm.api_request("PUT", "/vsock", Some(&vsock.to_string())).await {
            tracing::warn!("Failed to configure vsock for {} (recovery SSH unavailable): {}", sandbox_id, e);
            // Non-fatal — boot continues without vsock.
        }

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
            if let Ok(pub_hex) = std::env::var("MMDS_NOISE_BACKEND_PUBKEY") {
                if pub_hex.len() != 64 || !pub_hex.chars().all(|c| c.is_ascii_hexdigit()) {
                    anyhow::bail!("MMDS_NOISE_BACKEND_PUBKEY must be 64 hex chars");
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

    /// Build a fake /proc/<pid>/stat line with the given comm and starttime.
    /// Fields 1..=22 are: pid (comm) state ppid pgrp session tty_nr tpgid
    /// flags minflt cminflt majflt cmajflt utime stime cutime cstime
    /// priority nice num_threads itrealvalue starttime ...
    fn fake_stat(comm: &str, starttime: u64) -> String {
        let mut s = format!("1234 ({comm}) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 1 0 ");
        s.push_str(&starttime.to_string());
        s.push_str(" rest of stat...\n");
        s
    }

    #[test]
    fn parse_stat_basic() {
        assert_eq!(parse_proc_stat(&fake_stat("firecracker", 12345)), Some((12345, 'S')));
    }

    #[test]
    fn parse_stat_comm_with_spaces() {
        // Real-world cases: kernel threads, mangled comms.
        assert_eq!(parse_proc_stat(&fake_stat("foo bar", 7777)), Some((7777, 'S')));
    }

    #[test]
    fn parse_stat_comm_with_paren() {
        // `comm` can contain `)` because it's just truncated argv[0]. The
        // rsplit_once(") ") on the LAST occurrence still finds the right
        // boundary, since fields after comm are space-separated and don't
        // contain `") "`.
        assert_eq!(parse_proc_stat(&fake_stat("evil) name", 42)), Some((42, 'S')));
    }

    #[test]
    fn parse_stat_malformed() {
        assert_eq!(parse_proc_stat(""), None);
        assert_eq!(parse_proc_stat("no closing paren"), None);
    }

    #[test]
    fn parse_stat_zombie_state() {
        // Zombie process: state field is 'Z'. is_alive() consumes this and
        // returns false (see `is_alive()` body); here we only verify the
        // parser surfaces the state correctly.
        let raw = "1234 (firecracker) Z 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 1 0 999 rest...\n";
        assert_eq!(parse_proc_stat(raw), Some((999, 'Z')));
    }
}
