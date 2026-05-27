//! Lite sandbox backend — process-level isolation via `bwrap` (bubblewrap).
//!
//! Designed for unlogged/anonymous users (the FREE tier). No KVM, no
//! Firecracker — just a read-only rootfs and a writable `/root` dir.
//! Each `exec` runs inside a per-sandbox network namespace attached to
//! `br-sandbox-lite`, with nftables egress policy applied by
//! `ensure-bridge-lite.sh` (53/80/443 only, no RFC1918 / loopback /
//! metadata / SMTP / SSH).
//!
//! A lite sandbox has no long-running process. Each `exec` spawns a fresh
//! bwrap. `/root` (the sandbox `$HOME` — bwrap runs as uid 0 inside the
//! user namespace) is either:
//!   • the user's persistent home disk image, loop-mounted by `provision()`
//!     at `<scratch_root>/<id>/home` (authenticated tier — same `home.img`
//!     a VM sandbox of this user would attach as `/dev/vdb`), or
//!   • a plain dir `<scratch_root>/<id>/home` (anonymous tier — ephemeral).
//!
//! Loop mount: the host kernel wraps the image file in `/dev/loopN` and
//! mounts the ext4 inside it at our chosen path. The flock taken by the
//! caller (`VmManager::home_locks`) guarantees no VM sandbox of this user
//! has the same image attached at the same time — double-mounting an ext4
//! across two hosts (here: VM guest + host) would corrupt it.
//!
//! Rootfs layout requirements (built once, shipped read-only):
//!   /bin/<our-clis>      static binaries on the allow-list
//!   /root/               empty mount point (we --bind the chosen home here)
//!   /proc/, /dev/, /tmp/ empty mount points (--proc, --dev, --tmpfs)

use anyhow::{bail, Context, Result};
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tokio::process::Command;

/// Output of a single `exec` invocation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecOutput {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    /// True if either stdout or stderr was capped at `max_output_bytes`.
    #[serde(default)]
    pub truncated: bool,
}

/// Static config for the lite backend, loaded once at startup.
#[derive(Debug, Clone)]
pub struct LiteTemplate {
    /// Read-only directory bind-mounted as `/` inside the sandbox.
    /// Should contain only our CLI binaries + their minimal deps (libc, certs).
    pub rootfs_dir: PathBuf,
    /// Binaries (relative to rootfs_dir) that callers may invoke.
    /// Empty means "any path under /bin or /usr/bin".
    pub allowed_bins: Vec<String>,
}

pub struct LiteBackend {
    /// Per-sandbox scratch dirs live here: `<scratch_root>/<id>/`.
    scratch_root: PathBuf,
    /// Hard cap on exec wall-clock (seconds).
    timeout_sec: u64,
    /// Hard cap on combined stdout+stderr bytes returned.
    max_output_bytes: usize,
    /// Path to `lite-netns.sh` (per-exec netns wrapper). If `None`, bwrap
    /// runs in the host netns — only safe in dev. Production must point
    /// this at the installed helper so the nftables egress policy applies.
    netns_wrapper: Option<PathBuf>,
    /// Per-sandbox-id flag: `true` = `<scratch>/home` is a loop-mounted
    /// ext4 from the user's `home.img`, `false` = plain directory (anon).
    /// `destroy()` reads this to know whether to `umount` first.
    mounted: DashMap<String, bool>,
}

impl LiteBackend {
    pub fn new(scratch_root: PathBuf) -> Self {
        // Resolve netns wrapper: env override → installed path → none.
        // Installed path matches systemd/install.sh's LIB_DIR.
        let netns_wrapper = std::env::var_os("LITE_NETNS_WRAPPER")
            .map(PathBuf::from)
            .or_else(|| {
                let p = PathBuf::from("/usr/local/lib/sandbox-manager/lite-netns.sh");
                p.exists().then_some(p)
            });
        if netns_wrapper.is_none() {
            tracing::warn!(
                "lite-netns.sh not found — cli-lite sandboxes will share the host netns. \
                 Run systemd/install.sh and enable sandbox-bridge-lite.service before opening FREE tier."
            );
        }
        Self {
            scratch_root,
            timeout_sec: 30,
            max_output_bytes: 1 << 20,
            netns_wrapper,
            mounted: DashMap::new(),
        }
    }

    /// Host path bwrap will bind as `/root`. For authenticated users this
    /// is the loop-mounted disk's mountpoint; for anonymous, the same path
    /// is just an empty dir on host disk.
    fn home_mountpoint(&self, id: &str) -> PathBuf {
        self.scratch_root.join(id).join("home")
    }

    /// Allocate the sandbox's scratch dir and, if a `disk` path is given,
    /// loop-mount it at `<scratch>/home`. Idempotent w.r.t. the scratch
    /// dir; the mount call itself is not — calling twice with `disk=Some`
    /// is a bug (caller already holds the per-user home flock).
    ///
    /// `disk=None` → anonymous tier: `home` is a plain empty directory.
    pub async fn provision(&self, id: &str, disk: Option<&Path>) -> Result<()> {
        let mnt = self.home_mountpoint(id);
        tokio::fs::create_dir_all(&mnt).await
            .with_context(|| format!("create lite home mountpoint {mnt:?}"))?;

        if let Some(disk_path) = disk {
            // `mount -o loop`: kernel allocates a free /dev/loopN, binds it
            // to the image, mounts ext4. sandbox-manager already runs with
            // the privileges this needs (same caps as Firecracker spawn).
            let status = Command::new("mount")
                .args(["-o", "loop"])
                .arg(disk_path)
                .arg(&mnt)
                .status().await
                .with_context(|| format!("spawn mount -o loop {disk_path:?} {mnt:?}"))?;
            if !status.success() {
                anyhow::bail!("mount -o loop {disk_path:?} {mnt:?} exited {status}");
            }
            self.mounted.insert(id.to_string(), true);
            tracing::info!("lite {}: mounted {} → {}", id, disk_path.display(), mnt.display());
        } else {
            self.mounted.insert(id.to_string(), false);
        }
        Ok(())
    }

    /// Tear down. If a disk was loop-mounted in `provision`, unmount it
    /// first (the kernel releases the loop device automatically). Then
    /// remove the scratch dir. Best-effort: failures are logged, not
    /// returned — destroy is a cleanup path and the caller can't act on
    /// the error anyway.
    pub async fn destroy(&self, id: &str) {
        let mnt = self.home_mountpoint(id);
        let was_mounted = self.mounted.remove(id).map(|(_, v)| v).unwrap_or(false);
        if was_mounted {
            // `umount -l`: lazy detach. The mount goes away from the
            // filesystem tree immediately even if something inside still
            // has fds open; the actual cleanup happens when those close.
            // For Lite there shouldn't be open fds (bwrap exec is dead by
            // the time we get here), but lazy is the safe default.
            let status = Command::new("umount").arg("-l").arg(&mnt).status().await;
            match status {
                Ok(s) if s.success() => {}
                Ok(s) => tracing::warn!("lite {}: umount -l {} exited {}", id, mnt.display(), s),
                Err(e) => tracing::warn!("lite {}: spawn umount {}: {}", id, mnt.display(), e),
            }
        }
        let dir = self.scratch_root.join(id);
        let _ = tokio::fs::remove_dir_all(&dir).await;
    }

    /// Best-effort umount of `<scratch>/<id>/home` without touching our
    /// in-memory map. Used by `VmManager` startup reconcile to clean up
    /// leftover mounts from a previous (now-dead) sandbox-manager.
    pub async fn force_unmount_leftover(&self, id: &str) {
        let mnt = self.home_mountpoint(id);
        if !mnt.exists() { return }
        // Quick check: is something actually mounted there? `mountpoint -q`
        // returns 0 if yes. If not mounted, skip the umount.
        let is_mp = Command::new("mountpoint").arg("-q").arg(&mnt)
            .status().await.map(|s| s.success()).unwrap_or(false);
        if is_mp {
            let _ = Command::new("umount").arg("-l").arg(&mnt).status().await;
        }
    }

    /// Run `argv` inside a fresh bwrap jail rooted at `template.rootfs_dir`,
    /// with `<scratch>/<id>/home` bind-mounted at `/root` and cwd set to
    /// `/root`. Read-only rootfs. New PID/IPC/UTS/cgroup/user namespaces.
    ///
    /// Network: bwrap is launched via `lite-netns.sh <id> --` (when
    /// configured), which puts the whole jail in a per-exec network
    /// namespace attached to `br-sandbox-lite`. Egress is filtered by
    /// `ensure-bridge-lite.sh`'s nftables policy: allow 53/80/443 to public
    /// destinations only, drop RFC1918 + link-local + loopback + abuse
    /// ports. `bwrap --share-net` then inherits *that* filtered netns, not
    /// the host's.
    ///
    /// The contents seen at `/root` are determined by `provision()`: either
    /// the user's persistent disk (loop-mounted) or an empty scratch.
    pub async fn exec(
        &self,
        id: &str,
        template: &LiteTemplate,
        argv: &[String],
    ) -> Result<ExecOutput> {
        if argv.is_empty() { bail!("argv is empty"); }
        if !template.allowed_bins.is_empty() && !template.allowed_bins.iter().any(|b| b == &argv[0]) {
            bail!("binary not in allow-list: {}", argv[0]);
        }

        let home = self.home_mountpoint(id);
        if !home.is_dir() {
            bail!("lite sandbox {id} not provisioned (mountpoint {home:?} missing)");
        }

        // If a netns wrapper is configured, the outer command is the
        // wrapper script and bwrap becomes its child. Otherwise call bwrap
        // directly (dev / host-shared net — warned at startup).
        let mut cmd = match &self.netns_wrapper {
            Some(w) => {
                let mut c = Command::new(w);
                c.args([id, "--", "bwrap"]);
                c
            }
            None => Command::new("bwrap"),
        };
        cmd.args([
            "--ro-bind", path_str(&template.rootfs_dir)?, "/",
            "--bind", path_str(&home)?, "/root",
            "--proc", "/proc",
            "--dev", "/dev",
            "--tmpfs", "/tmp",
            "--unshare-all",         // user/pid/ipc/uts/cgroup/net
            "--share-net",           // inherit the (filtered) netns we're already in
            "--die-with-parent",
            "--new-session",
            "--chdir", "/root",
            "--clearenv",
            "--setenv", "PATH", "/usr/bin:/bin",
            "--setenv", "HOME", "/root",
            "--setenv", "SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt",
            "--setenv", "SSL_CERT_DIR", "/etc/ssl/certs",
            "--",
        ]);
        cmd.args(argv);
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        cmd.kill_on_drop(true);

        let child = cmd.spawn().context("spawn lite exec")?;
        let out = match tokio::time::timeout(
            std::time::Duration::from_secs(self.timeout_sec),
            child.wait_with_output(),
        ).await {
            Ok(r) => r.context("lite exec wait")?,
            Err(_) => bail!("exec timed out after {}s", self.timeout_sec),
        };

        let (stdout, t1) = truncate_utf8(out.stdout, self.max_output_bytes);
        let (stderr, t2) = truncate_utf8(out.stderr, self.max_output_bytes);
        Ok(ExecOutput {
            exit_code: out.status.code().unwrap_or(-1),
            stdout,
            stderr,
            truncated: t1 || t2,
        })
    }
}

fn path_str(p: &Path) -> Result<&str> {
    p.to_str().with_context(|| format!("non-utf8 path: {p:?}"))
}

fn truncate_utf8(mut bytes: Vec<u8>, max: usize) -> (String, bool) {
    let truncated = bytes.len() > max;
    if truncated { bytes.truncate(max); }
    (String::from_utf8_lossy(&bytes).into_owned(), truncated)
}
