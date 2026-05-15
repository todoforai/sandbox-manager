//! Lite sandbox backend — process-level isolation via `bwrap` (bubblewrap).
//!
//! Designed for unlogged/anonymous users (the FREE tier). No KVM, no
//! Firecracker — just a read-only rootfs and a writable `/work` dir,
//! with host-shared networking so HTTPS / git / package installs work.
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
    /// True if either stdout or stderr was capped at `max_output_bytes`.
    #[serde(default)]
    pub truncated: bool,
}

/// Extra mounts injected into a single `exec` (typically credential dirs from
/// the host, so CLI tools can find their auth fil under `$HOME` inside the
/// sandbox). Sandbox-side paths are absolute; if they live under `/work`
/// (i.e. `$HOME`), the bind is created on the scratch dir before bwrap starts.
#[derive(Debug, Clone, Default)]
pub struct ExecBinds {
    /// Read-only host → sandbox path pairs (e.g. shared certs, read-only creds).
    pub ro: Vec<(PathBuf, String)>,
    /// Read-write host → sandbox path pairs (e.g. credential dirs for login flows).
    pub rw: Vec<(PathBuf, String)>,
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
    pub async fn exec(
        &self,
        id: &str,
        template: &LiteTemplate,
        argv: &[String],
        binds: &ExecBinds,
    ) -> Result<ExecOutput> {
        if argv.is_empty() { bail!("argv is empty"); }
        if !template.allowed_bins.is_empty() && !template.allowed_bins.iter().any(|b| b == &argv[0]) {
            bail!("binary not in allow-list: {}", argv[0]);
        }
        validate_binds(binds)?;

        let scratch = self.provision(id).await?;
        // Bind targets under /work must exist on the scratch FS before bwrap
        // tries to mount onto them, otherwise bwrap errors out.
        prepare_scratch_mountpoints(&scratch, binds).await?;

        let mut cmd = Command::new("bwrap");
        cmd.args([
            "--ro-bind", path_str(&template.rootfs_dir)?, "/",
            "--bind", path_str(&scratch)?, "/work",
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
        ]);
        for (host, sb) in &binds.ro {
            cmd.args(["--ro-bind", path_str(host)?, sb.as_str()]);
        }
        for (host, sb) in &binds.rw {
            cmd.args(["--bind", path_str(host)?, sb.as_str()]);
        }
        cmd.arg("--");
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

/// Bind targets must live strictly under `/work/<something>` (i.e. inside
/// the sandbox HOME). That's the whole purpose: mapping host credential
/// dirs onto `$HOME/...` inside the sandbox. We refuse anything else so a
/// future buggy caller can't shadow `/usr`, `/etc`, `/proc`, the rootfs, etc.
///
/// Each segment after `/work/` must be a real non-empty component — no
/// `//`, no `.`/`..`, no trailing slash. `prepare_scratch_mountpoints`
/// relies on the relative path being safe to `join` onto the scratch dir.
fn validate_binds(binds: &ExecBinds) -> Result<()> {
    for (_, sb) in binds.ro.iter().chain(binds.rw.iter()) {
        let Some(rel) = sb.strip_prefix("/work/") else {
            bail!("bind target must be under /work/: {sb}");
        };
        if rel.is_empty() {
            bail!("bind target has empty path under /work/: {sb}");
        }
        for seg in rel.split('/') {
            if seg.is_empty() || seg == "." || seg == ".." {
                bail!("bind target has empty or traversal segment: {sb}");
            }
        }
    }
    Ok(())
}

/// For binds whose sandbox path lives under `/work`, the mountpoint must
/// already exist on the underlying scratch FS. Create dirs (or empty files)
/// based on whether the host source is a dir or a file.
///
/// Refuses to traverse through symlinks anywhere along the mountpoint path.
/// A prior sandbox exec could have written symlinks into the scratch tree
/// (it's user-writable), and `create_dir_all` would happily follow them,
/// letting the host-side mountpoint resolve outside the intended scratch.
async fn prepare_scratch_mountpoints(scratch: &Path, binds: &ExecBinds) -> Result<()> {
    for (host, sb) in binds.ro.iter().chain(binds.rw.iter()) {
        let Some(rel) = sb.strip_prefix("/work/") else { continue };
        let target = scratch.join(rel);

        // Walk every existing ancestor of `target` (down to `scratch` itself)
        // and reject if any component is a symlink.
        let mut cur = scratch.to_path_buf();
        reject_symlink(&cur).await?;
        for seg in rel.split('/') {
            cur.push(seg);
            // Use symlink_metadata so we see the link itself, not its target.
            match tokio::fs::symlink_metadata(&cur).await {
                Ok(m) if m.file_type().is_symlink() => {
                    bail!("scratch mountpoint path contains a symlink: {cur:?}");
                }
                Ok(_) | Err(_) => {}
            }
        }

        let meta = tokio::fs::symlink_metadata(host).await
            .with_context(|| format!("bind source missing: {}", host.display()))?;
        if meta.file_type().is_symlink() {
            bail!("bind source is a symlink: {}", host.display());
        }
        if meta.is_dir() {
            tokio::fs::create_dir_all(&target).await
                .with_context(|| format!("create mountpoint dir {target:?}"))?;
        } else {
            if let Some(parent) = target.parent() {
                tokio::fs::create_dir_all(parent).await
                    .with_context(|| format!("create mountpoint parent {parent:?}"))?;
            }
            if tokio::fs::symlink_metadata(&target).await.is_err() {
                tokio::fs::File::create(&target).await
                    .with_context(|| format!("create mountpoint file {target:?}"))?;
            }
        }
    }
    Ok(())
}

async fn reject_symlink(p: &Path) -> Result<()> {
    if let Ok(m) = tokio::fs::symlink_metadata(p).await {
        if m.file_type().is_symlink() {
            bail!("scratch path component is a symlink: {p:?}");
        }
    }
    Ok(())
}

fn truncate_utf8(mut bytes: Vec<u8>, max: usize) -> (String, bool) {
    let truncated = bytes.len() > max;
    if truncated { bytes.truncate(max); }
    (String::from_utf8_lossy(&bytes).into_owned(), truncated)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binds(rw: &[(&str, &str)]) -> ExecBinds {
        ExecBinds {
            ro: vec![],
            rw: rw.iter().map(|(h, s)| (PathBuf::from(h), s.to_string())).collect(),
        }
    }

    #[test]
    fn validate_rejects_non_work_targets() {
        for bad in ["work/x", "/", "/proc", "/dev", "/tmp", "/work", "/etc/passwd", "/usr/bin/x"] {
            assert!(validate_binds(&binds(&[("/etc", bad)])).is_err(), "should reject {bad}");
        }
    }

    #[test]
    fn validate_rejects_traversal() {
        for bad in ["/work/../etc", "/work/foo/../bar", "/work/foo/.."] {
            assert!(validate_binds(&binds(&[("/etc", bad)])).is_err(), "should reject {bad}");
        }
    }

    #[test]
    fn validate_rejects_empty_or_double_slash() {
        for bad in ["/work/", "/work//x", "/work/foo//bar", "/work/foo/"] {
            assert!(validate_binds(&binds(&[("/etc", bad)])).is_err(), "should reject {bad}");
        }
    }

    #[test]
    fn validate_accepts_work_subpath() {
        assert!(validate_binds(&binds(&[("/etc", "/work/.config/gh")])).is_ok());
    }

    #[tokio::test]
    async fn prepare_rejects_symlinked_mountpoint() {
        let scratch = tempfile::tempdir().unwrap();
        let host = tempfile::tempdir().unwrap();
        // Put a symlink in the scratch tree at the place the next exec
        // would try to mount onto. Simulates malicious prior exec output.
        let evil_target = tempfile::tempdir().unwrap();
        tokio::fs::symlink(evil_target.path(), scratch.path().join(".config"))
            .await.unwrap();
        let b = ExecBinds {
            ro: vec![],
            rw: vec![(host.path().to_path_buf(), "/work/.config/gh".into())],
        };
        let err = prepare_scratch_mountpoints(scratch.path(), &b).await.unwrap_err();
        assert!(err.to_string().contains("symlink"), "got: {err}");
        // And the evil target was not written into.
        assert!(tokio::fs::read_dir(evil_target.path()).await.unwrap().next_entry().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn prepare_rejects_symlinked_bind_source() {
        let scratch = tempfile::tempdir().unwrap();
        let real = tempfile::tempdir().unwrap();
        let link_dir = tempfile::tempdir().unwrap();
        let link = link_dir.path().join("via-symlink");
        tokio::fs::symlink(real.path(), &link).await.unwrap();
        let b = ExecBinds {
            ro: vec![],
            rw: vec![(link, "/work/.config".into())],
        };
        let err = prepare_scratch_mountpoints(scratch.path(), &b).await.unwrap_err();
        assert!(err.to_string().contains("symlink"), "got: {err}");
    }

    #[tokio::test]
    async fn prepare_creates_dir_mountpoint() {
        let scratch = tempfile::tempdir().unwrap();
        let host = tempfile::tempdir().unwrap();
        let b = ExecBinds {
            ro: vec![],
            rw: vec![(host.path().to_path_buf(), "/work/.config/gh".into())],
        };
        prepare_scratch_mountpoints(scratch.path(), &b).await.unwrap();
        assert!(scratch.path().join(".config/gh").is_dir());
    }

    #[tokio::test]
    async fn prepare_creates_file_mountpoint() {
        let scratch = tempfile::tempdir().unwrap();
        let host_file = tempfile::NamedTempFile::new().unwrap();
        let b = ExecBinds {
            ro: vec![(host_file.path().to_path_buf(), "/work/.netrc".into())],
            rw: vec![],
        };
        prepare_scratch_mountpoints(scratch.path(), &b).await.unwrap();
        assert!(scratch.path().join(".netrc").is_file());
    }

    #[tokio::test]
    async fn prepare_errors_on_missing_source() {
        let scratch = tempfile::tempdir().unwrap();
        let b = ExecBinds {
            ro: vec![],
            rw: vec![(PathBuf::from("/nonexistent/path/xyz"), "/work/x".into())],
        };
        assert!(prepare_scratch_mountpoints(scratch.path(), &b).await.is_err());
    }
}
