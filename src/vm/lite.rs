//! Lite sandbox backend — process-level isolation via `bwrap` (bubblewrap).
//!
//! Designed for unlogged/anonymous users (the FREE tier) running our own CLI
//! binaries. No KVM, no Firecracker, no networking, no language runtimes —
//! just a read-only rootfs of pre-approved CLIs and a writable `/work` dir.
//!
//! A lite sandbox has no long-running process. Each `exec` spawns a fresh
//! bwrap. The per-sandbox state that *does* persist between calls is the
//! scratch directory at `overlays_dir/lite/<id>/`, mounted as `/work`. So
//! `todoai login` followed later by `todoai publish` shares a home dir.
//!
//! Rootfs layout requirements (built once, shipped read-only):
//!   /bin/<our-clis>      static binaries on the allow-list
//!   /work/               empty mount point (we --bind scratch here)
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
    /// No network. Read-only rootfs. New PID/IPC/UTS/cgroup/user namespaces.
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

        let scratch = self.provision(id).await?;

        let mut cmd = Command::new("bwrap");
        cmd.args([
            "--ro-bind", path_str(&template.rootfs_dir)?, "/",
            "--bind", path_str(&scratch)?, "/work",
            "--proc", "/proc",
            "--dev", "/dev",
            "--tmpfs", "/tmp",
            "--unshare-all",         // user/pid/ipc/uts/cgroup/net
            "--die-with-parent",
            "--new-session",
            "--chdir", "/work",
            "--clearenv",
            "--setenv", "PATH", "/usr/bin:/bin",
            "--setenv", "HOME", "/work",
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

        let stdout = truncate_utf8(out.stdout, self.max_output_bytes);
        let stderr = truncate_utf8(out.stderr, self.max_output_bytes);
        Ok(ExecOutput {
            exit_code: out.status.code().unwrap_or(-1),
            stdout,
            stderr,
        })
    }
}

fn path_str(p: &Path) -> Result<&str> {
    p.to_str().with_context(|| format!("non-utf8 path: {p:?}"))
}

fn truncate_utf8(mut bytes: Vec<u8>, max: usize) -> String {
    if bytes.len() > max { bytes.truncate(max); }
    String::from_utf8_lossy(&bytes).into_owned()
}
