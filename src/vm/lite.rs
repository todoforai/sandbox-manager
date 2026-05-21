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
//! user namespace) is either the caller's persistent per-user host home
//! (authenticated tier — the source of truth, bind-mounted directly) or
//! a per-sandbox ephemeral scratch at `overlays_dir/lite/<id>/`
//! (anonymous tier — clean every time).
//!
//! Rootfs layout requirements (built once, shipped read-only):
//!   /bin/<our-clis>      static binaries on the allow-list
//!   /root/               empty mount point (we --bind the chosen home here)
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
    /// Path to `lite-netns.sh` (per-exec netns wrapper). If `None`, bwrap
    /// runs in the host netns — only safe in dev. Production must point
    /// this at the installed helper so the nftables egress policy applies.
    netns_wrapper: Option<PathBuf>,
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
        }
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
    /// with `<scratch_root>/<id>/` mounted at `/root` and cwd set to `/root`.
    /// Read-only rootfs. New PID/IPC/UTS/cgroup/user namespaces.
    ///
    /// Network: bwrap is launched via `lite-netns.sh <id> --` (when
    /// configured), which puts the whole jail in a per-exec network
    /// namespace attached to `br-sandbox-lite`. Egress is filtered by
    /// `ensure-bridge-lite.sh`'s nftables policy: allow 53/80/443 to public
    /// destinations only, drop RFC1918 + link-local + loopback + abuse
    /// ports. `bwrap --share-net` then inherits *that* filtered netns, not
    /// the host's.
    ///
    /// `/root` (the sandbox `$HOME`) is either the caller's persistent
    /// per-user dir (`home_override = Some(...)`) or the per-sandbox
    /// scratch dir (`None`, anonymous tier).
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
            "--bind", path_str(home)?, "/root",
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
