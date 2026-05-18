//! Lite sandbox backend — process-level isolation via `bwrap` (bubblewrap).
//!
//! Designed for unlogged/anonymous users (the FREE tier). No KVM, no
//! Firecracker — just a read-only rootfs and a writable `/work` dir,
//! with host-shared networking so HTTPS / git / package installs work.
//!
//! A lite sandbox has no long-running process. Each `exec` spawns a fresh
//! bwrap. `/work` (the sandbox `$HOME`) is either the caller's persistent
//! per-user host home (authenticated tier — the source of truth, bind-
//! mounted directly) or a per-sandbox ephemeral scratch at
//! `overlays_dir/lite/<id>/` (anonymous tier — clean every time).
//!
//! Rootfs layout requirements (built once, shipped read-only):
//!   /bin/<our-clis>      static binaries on the allow-list
//!   /work/               empty mount point (we --bind the chosen home here)
//!   /proc/, /dev/, /tmp/ empty mount points (--proc, --dev, --tmpfs)

use anyhow::{bail, Context, Result};
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

#[derive(Clone)]
pub struct LiteBackend {
    /// Per-sandbox scratch dirs live here: `<scratch_root>/<id>/`.
    scratch_root: PathBuf,
    /// Hard cap on exec wall-clock (seconds).
    timeout_sec: u64,
    /// Hard cap on combined stdout+stderr bytes returned.
    max_output_bytes: usize,
}

impl LiteBackend {
    pub fn new(scratch_root: PathBuf) -> Self {
        Self { scratch_root, timeout_sec: 30, max_output_bytes: 1 << 20 }
    }

    /// Allocate the scratch dir. Idempotent.
    pub async fn provision(&self, id: &str) -> Result<PathBuf> {
        let dir = self.scratch_root.join(id);
        tokio::fs::create_dir_all(&dir).await
            .with_context(|| format!("create scratch dir {dir:?}"))?;
        Ok(dir)
    }

    /// Remove the scratch dir. Best-effort.
    pub async fn destroy(&self, id: &str) {
        let dir = self.scratch_root.join(id);
        let _ = tokio::fs::remove_dir_all(&dir).await;
    }

    /// Run `argv` inside a fresh bwrap jail rooted at `template.rootfs_dir`,
    /// with `<scratch_root>/<id>/` mounted at `/work` and cwd set to `/work`.
    /// Read-only rootfs. New PID/IPC/UTS/cgroup/user namespaces. Net is
    /// shared with the host (no per-sandbox netns isolation) — outbound
    /// abuse must be limited at the host firewall level.
    /// Run `argv` inside a fresh bwrap jail. `/work` (the sandbox `$HOME`)
    /// is either the caller's persistent per-user dir (`home_override =
    /// Some(...)`) or the per-sandbox scratch dir (`None`, anonymous tier).
    pub async fn exec(
        &self,
        id: &str,
        template: &LiteTemplate,
        argv: &[String],
        home_override: Option<&Path>,
    ) -> Result<ExecOutput> {
        if argv.is_empty() { bail!("argv is empty"); }
        if !template.allowed_bins.is_empty() && !template.allowed_bins.iter().any(|b| b == &argv[0]) {
            bail!("binary not in allow-list: {}", argv[0]);
        }

        // Anonymous (no user) → ephemeral scratch dir as HOME. Authed user
        // → their persistent home dir, mounted in directly. One bind, no
        // partial overlays, no surprises.
        let scratch = self.provision(id).await?;
        let home = home_override.unwrap_or(&scratch);

        let mut cmd = Command::new("bwrap");
        cmd.args([
            "--ro-bind", path_str(&template.rootfs_dir)?, "/",
            "--bind", path_str(home)?, "/work",
            "--proc", "/proc",
            "--dev", "/dev",
            "--tmpfs", "/tmp",
            "--unshare-all",         // user/pid/ipc/uts/cgroup/net
            "--share-net",           // re-share net so HTTPS, DNS, git clone work
            "--die-with-parent",
            "--new-session",
            "--chdir", "/work",
            "--clearenv",
            "--setenv", "PATH", "/usr/bin:/bin",
            "--setenv", "HOME", "/work",
            "--setenv", "SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt",
            "--setenv", "SSL_CERT_DIR", "/etc/ssl/certs",
            "--",
        ]);
        cmd.args(argv);
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        cmd.kill_on_drop(true);

        let child = cmd.spawn().context("spawn bwrap")?;
        let out = match tokio::time::timeout(
            std::time::Duration::from_secs(self.timeout_sec),
            child.wait_with_output(),
        ).await {
            Ok(r) => r.context("bwrap wait")?,
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
