//! virtiofsd process management — host-side virtio-fs daemon.
//!
//! Exports a single host directory (`<user_home_root>/<user_id>/`) over a
//! vhost-user UDS that Firecracker connects to as a `vhost-user-fs` device.
//! Inside the guest, `/init` runs `mount -t virtiofs userhome /root` to
//! land that directory as the sandbox `$HOME`. The bytes are the same the
//! Lite tier sees — rotation between Lite and VM needs zero transition.
//!
//! Lifecycle mirrors `firecracker::FirecrackerLauncher`:
//!   - spawn detached via `setsid()` so PM2 / manager restart doesn't kill it
//!   - identify by `(pid, /proc/<pid>/stat.starttime)` to defend against PID reuse
//!   - drop the `Child` handle; PID 1 reaps on exit
//!   - control plane is purely "is it alive?" → SIGTERM / SIGKILL on shutdown
//!
//! Required virtiofsd flags (chosen for our threat model + Lite↔VM
//! rotation semantics):
//!   --socket-path <uds>  Where FC connects. One per VM.
//!   --shared-dir  <dir>  Host directory exposed to the guest.
//!   --xattr              Pass through extended attrs so anything a user's
//!                        tools set in Lite (where /root is a plain bind
//!                        mount) survives a rotation into a VM, and vice
//!                        versa. Cheap to leave on.
//!   --cache=auto         Coherent enough: anything written to the host
//!                        directory from outside the VM (Lite shell on the
//!                        same host, an admin shell, a backup restore) is
//!                        seen by guest within seconds. For instant reads
//!                        guest can `echo 3 > /proc/sys/vm/drop_caches`.
//!                        We do NOT use `--cache=always` (would mask host
//!                        writes) nor `--cache=none` (kills perf for normal
//!                        $HOME use).
//!   --sandbox=none       virtiofsd's own sandbox uses pivot_root which
//!                        requires the shared dir to be a mountpoint. Our
//!                        per-user dirs aren't. We accept this (the FC VM
//!                        is the real isolation boundary) — virtiofsd is
//!                        trusted manager-side code.

use anyhow::{Context, Result};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use super::firecracker::read_proc_starttime;

/// Locate the `virtiofsd` binary. Installed by scripts/setup.sh.
fn which_virtiofsd() -> Result<PathBuf> {
    for p in ["/usr/local/bin/virtiofsd", "/usr/bin/virtiofsd"] {
        let pb = PathBuf::from(p);
        if pb.exists() { return Ok(pb); }
    }
    if let Ok(out) = Command::new("which").arg("virtiofsd").output() {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !s.is_empty() { return Ok(PathBuf::from(s)); }
        }
    }
    anyhow::bail!("virtiofsd binary not found; run sandbox-manager/scripts/setup.sh");
}

/// Handle to a running virtiofsd. Identified by `(pid, starttime)` so we
/// can re-attach across a manager restart and refuse to signal a reused PID.
pub struct VirtiofsdProcess {
    pid: u32,
    starttime: u64,
    socket_path: PathBuf,
    /// Kept for diagnostics / re-attach (`shared_dir` cannot change while
    /// the daemon is running, so we don't expose mutation).
    #[allow(dead_code)]
    shared_dir: PathBuf,
}

impl VirtiofsdProcess {
    pub fn pid(&self) -> u32 { self.pid }
    pub fn starttime(&self) -> u64 { self.starttime }
    pub fn socket_path(&self) -> &Path { &self.socket_path }

    /// Re-attach to an already-running virtiofsd. Returns `None` if the pid
    /// is gone OR `/proc/<pid>/stat` starttime doesn't match (PID reuse).
    pub fn attach(pid: u32, expected_starttime: u64, socket_path: PathBuf, shared_dir: PathBuf) -> Option<Self> {
        let actual = read_proc_starttime(pid)?;
        if actual != expected_starttime { return None }
        Some(Self { pid, starttime: actual, socket_path, shared_dir })
    }

    /// SIGTERM → grace → SIGKILL. virtiofsd has no API socket and no state
    /// of its own to flush — guest fsyncs already hit the host page cache
    /// directly, so signal-and-walk-away is correct.
    pub async fn shutdown(self) {
        // Best-effort SIGTERM; if the process is already gone (kernel reaped
        // after PID 1 inherited it), `kill` returns ESRCH and we move on.
        unsafe { libc::kill(self.pid as i32, libc::SIGTERM); }
        // Grace window: virtiofsd exits in <100ms once its FC peer closes,
        // so 1s is generous. Poll cheap.
        for _ in 0..20 {
            if !is_pid_alive(self.pid, self.starttime) {
                let _ = std::fs::remove_file(&self.socket_path);
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        // Last resort.
        unsafe { libc::kill(self.pid as i32, libc::SIGKILL); }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

fn is_pid_alive(pid: u32, expected_starttime: u64) -> bool {
    matches!(read_proc_starttime(pid), Some(st) if st == expected_starttime)
}

#[derive(Clone)]
pub struct VirtiofsdLauncher {
    binary: PathBuf,
    /// Where per-VM sockets live. Same dir FC uses for its API + vsock
    /// sockets — keeps cleanup uniform.
    runtime_dir: PathBuf,
}

impl VirtiofsdLauncher {
    pub fn new(runtime_dir: PathBuf) -> Result<Self> {
        let binary = which_virtiofsd().context("locate virtiofsd")?;
        tracing::debug!("Found virtiofsd at: {:?}", binary);
        std::fs::create_dir_all(&runtime_dir)
            .with_context(|| format!("create runtime dir {runtime_dir:?}"))?;
        Ok(Self { binary, runtime_dir })
    }

    /// vhost-user-fs UDS for this VM. FC's `/vhost-user-fs` PUT will use
    /// this path; virtiofsd binds it.
    pub fn socket_path_for(&self, vm_id: &str) -> PathBuf {
        self.runtime_dir.join(format!("{vm_id}.vfs.sock"))
    }

    /// Spawn virtiofsd, wait for the UDS to appear, return the handle.
    ///
    /// `shared_dir` MUST exist on disk before this is called (caller is the
    /// `UserHomeStore`, which is idempotent). virtiofsd will refuse to start
    /// against a missing directory.
    pub async fn spawn(&self, vm_id: &str, shared_dir: &Path) -> Result<VirtiofsdProcess> {
        if !shared_dir.is_dir() {
            anyhow::bail!("virtiofs shared dir {} is not a directory", shared_dir.display());
        }
        let socket_path = self.socket_path_for(vm_id);
        let log_path = self.runtime_dir.join(format!("{vm_id}.vfs.log"));

        // Stale UDS from a previous incarnation breaks `bind`; remove first.
        std::fs::remove_file(&socket_path).ok();

        let log = std::fs::File::create(&log_path)
            .with_context(|| format!("create {}", log_path.display()))?;
        let log_err = log.try_clone()
            .with_context(|| format!("clone log fd for {}", log_path.display()))?;

        // virtiofsd 1.x flags. `--cache=auto` is the sweet spot for $HOME
        // (see module docs). `--xattr` preserves attrs across Lite↔VM
        // rotation. `--sandbox=none` because our shared dirs are not
        // mountpoints; the VM is the isolation boundary.
        let mut cmd = Command::new(&self.binary);
        cmd.args([
            "--socket-path", socket_path.to_str().context("non-utf8 socket path")?,
            "--shared-dir",  shared_dir.to_str().context("non-utf8 shared dir")?,
            "--cache",       "auto",
            "--sandbox",     "none",
            "--xattr",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));

        // Detach: own session/pgroup so manager's PM2 SIGTERM doesn't cascade.
        unsafe {
            cmd.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = cmd.spawn().context("spawn virtiofsd")?;
        let pid = child.id();
        drop(child); // reparent to PID 1; we identify by pid+starttime

        // Wait for the UDS to appear — FC's `/vhost-user-fs` PUT requires
        // the socket to already be listening. Same 50×20ms budget as FC.
        for _ in 0..50 {
            if socket_path.exists() { break; }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        if !socket_path.exists() {
            // Reap inline so we don't leak a half-started virtiofsd.
            unsafe {
                libc::kill(pid as i32, libc::SIGKILL);
                let mut status = 0i32;
                libc::waitpid(pid as i32, &mut status, 0);
            }
            anyhow::bail!(
                "virtiofsd socket {} not created in 1s (check {})",
                socket_path.display(), log_path.display(),
            );
        }

        let starttime = read_proc_starttime(pid)
            .with_context(|| format!("read /proc/{pid}/stat for virtiofsd starttime"))?;

        tracing::info!(
            "virtiofsd up for VM {} (pid={}, shared_dir={}, socket={})",
            vm_id, pid, shared_dir.display(), socket_path.display(),
        );

        Ok(VirtiofsdProcess {
            pid,
            starttime,
            socket_path,
            shared_dir: shared_dir.to_path_buf(),
        })
    }
}
