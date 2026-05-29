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
use tokio::io::AsyncWriteExt;
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
    /// ext4 from the user's `home.img`, `false` (or absent) = plain
    /// directory (anon). `destroy()` reads this to decide whether to call
    /// the unmount helper.
    mounted: DashMap<String, bool>,
    /// Path to `lite-mount-home.sh`. See `Self::new` for resolution order.
    mount_helper: PathBuf,
}

impl LiteBackend {
    pub fn new(scratch_root: PathBuf) -> Self {
        // Resolve helper script paths the same way for both:
        //   1. $LITE_*_WRAPPER / $LITE_*_HELPER env (tests / oddball dev)
        //   2. /usr/local/lib/sandbox-manager/<name>.sh (systemd/install.sh)
        //   3. ../scripts/<name>.sh next to the binary (cargo run from repo)
        fn resolve_helper(env: &str, name: &str) -> Option<PathBuf> {
            std::env::var_os(env).map(PathBuf::from)
                .or_else(|| {
                    let installed = PathBuf::from(format!("/usr/local/lib/sandbox-manager/{name}"));
                    installed.exists().then_some(installed)
                })
                .or_else(|| {
                    // cargo run / dev: binary is target/release/sandbox-manager
                    // → scripts are ../../scripts/<name>
                    let exe = std::env::current_exe().ok()?;
                    let candidate = exe.parent()?.parent()?.parent()?
                        .join("scripts").join(name);
                    candidate.exists().then_some(candidate)
                })
        }

        let netns_wrapper = resolve_helper("LITE_NETNS_WRAPPER", "lite-netns.sh");
        if netns_wrapper.is_none() {
            tracing::warn!(
                "lite-netns.sh not found — cli-lite sandboxes will share the host netns. \
                 Run systemd/install.sh and enable sandbox-bridge-lite.service before opening FREE tier."
            );
        }

        // Mount helper is mandatory for the authenticated tier; we fail
        // loudly at provision time (not here) if it's missing, so anon
        // tier still works without the install.sh step.
        let mount_helper = resolve_helper("LITE_MOUNT_HELPER", "lite-mount-home.sh")
            .unwrap_or_else(|| PathBuf::from("/usr/local/lib/sandbox-manager/lite-mount-home.sh"));

        Self {
            scratch_root,
            timeout_sec: 30,
            max_output_bytes: 1 << 20,
            netns_wrapper,
            mounted: DashMap::new(),
            mount_helper,
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
            // Shell out to the privileged helper (sudo no-op when we're
            // already root). Same code path on dev and prod — no caps
            // dance, no devtmpfs games. See scripts/lite-mount-home.sh.
            let out = run_helper(&self.mount_helper, &["attach", path_str(disk_path)?, path_str(&mnt)?]).await
                .with_context(|| format!("lite-mount-home attach {disk_path:?} → {mnt:?}"))?;
            self.mounted.insert(id.to_string(), true);
            tracing::info!("lite {}: mounted {} via {} → {}",
                id, disk_path.display(), out.trim(), mnt.display());
        }
        Ok(())
    }

    /// Tear down. If a disk was loop-mounted in `provision`, unmount the
    /// ext4 and detach the loop device. Then remove the scratch dir.
    /// Best-effort: failures are logged, not returned — destroy is a
    /// cleanup path and the caller can't act on the error anyway.
    pub async fn destroy(&self, id: &str) {
        let mnt = self.home_mountpoint(id);
        if let Some((_, was_mounted)) = self.mounted.remove(id) {
            if was_mounted {
                // Synchronous: ext4 writeout finishes before this returns,
                // so a tier flip can hand the image to FC without racing.
                if let Ok(mnt_str) = path_str(&mnt) {
                    if let Err(e) = run_helper(&self.mount_helper, &["detach", mnt_str]).await {
                        tracing::warn!("lite {}: detach {}: {:#}", id, mnt.display(), e);
                    }
                }
            }
        }
        let dir = self.scratch_root.join(id);
        let _ = tokio::fs::remove_dir_all(&dir).await;
    }

    /// Best-effort umount of `<scratch>/<id>/home` without touching our
    /// in-memory map. Used by `VmManager` startup reconcile to clean up
    /// leftover mounts from a previous (now-dead) sandbox-manager.
    /// The helper's `detach` subcommand also frees the backing loop
    /// device — important across restarts because we lost the in-memory
    /// loop-device map.
    pub async fn force_unmount_leftover(&self, id: &str) {
        let mnt = self.home_mountpoint(id);
        if !mnt.exists() { return }
        if let Ok(mnt_str) = path_str(&mnt) {
            let _ = run_helper(&self.mount_helper, &["detach", mnt_str]).await;
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

    /// Probe the tool catalog inside the jail. Mirrors `bridge_scan_tools()`
    /// in `bridge/tools.c` — same wire format in (`<key>\t<b64_versionCmd>\t
    /// <b64_statusCmd>\n`; trailing install field, if present, is ignored
    /// here — installs go through a separate `install_tool` path), same JSON
    /// shape out: `{ "<toolName>": { installed, version?, authenticated?,
    /// statusOutput? } }`. Triggered explicitly by the backend; no periodic
    /// scan. Per-probe timeouts match the bridge (`VERSION_TIMEOUT_MS=5s`,
    /// `STATUS_TIMEOUT_MS=10s`); an outer wall-clock cap (`SCAN_TIMEOUT_SEC`)
    /// bounds the whole scan.
    ///
    /// **Safety:** runs the same bwrap flags as `exec`. The catalog content
    /// goes through `sh -c`, which bypasses `exec`'s `allowed_bins` argv[0]
    /// allow-list — but the jail itself (read-only rootfs, unshare-all,
    /// filtered netns, bound `/root`) is the actual containment boundary,
    /// not the allow-list. Same trust model as `exec` running an
    /// allow-listed shell. Catalog is fed via stdin (no argv size limit).
    pub async fn scan_tools(
        &self,
        id: &str,
        template: &LiteTemplate,
        entries: &str,
    ) -> Result<String> {
        const SCAN_TIMEOUT_SEC: u64 = 240;
        const MAX_SCAN_OUTPUT: usize = 4 << 20; // 4 MiB

        let home = self.home_mountpoint(id);
        if !home.is_dir() {
            bail!("lite sandbox {id} not provisioned (mountpoint {home:?} missing)");
        }

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
            "--unshare-all",
            "--share-net",
            "--die-with-parent",
            "--new-session",
            "--chdir", "/root",
            "--clearenv",
            "--setenv", "PATH", "/usr/bin:/bin",
            "--setenv", "HOME", "/root",
            "--setenv", "SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt",
            "--setenv", "SSL_CERT_DIR", "/etc/ssl/certs",
            "--",
            "sh", "-c", SCAN_TOOLS_SCRIPT,
        ]);
        cmd.stdin(std::process::Stdio::piped());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        cmd.kill_on_drop(true);

        let mut child = cmd.spawn().context("spawn lite scan_tools")?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(entries.as_bytes()).await.context("write catalog to scan_tools stdin")?;
            // drop stdin to send EOF
        }

        let out = match tokio::time::timeout(
            std::time::Duration::from_secs(SCAN_TIMEOUT_SEC),
            child.wait_with_output(),
        ).await {
            Ok(r) => r.context("lite scan_tools wait")?,
            Err(_) => bail!("scan_tools timed out after {SCAN_TIMEOUT_SEC}s"),
        };

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            bail!("scan_tools exited {}: {}", out.status, stderr.trim());
        }
        // Truncation would yield invalid JSON — bridge bails on overflow
        // (bridge/tools.c:482-490); do the same here.
        if out.stdout.len() > MAX_SCAN_OUTPUT {
            bail!("scan_tools output exceeded {MAX_SCAN_OUTPUT} bytes");
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

/// In-jail probe loop. Reads tab-separated, base64-encoded catalog entries
/// from stdin (one per line: `<key>\t<b64_versionCmd>\t<b64_statusCmd>`;
/// any 4th install field is ignored — installs go through a separate
/// `install_tool` path), runs each tool's version/status with per-probe
/// timeouts (5s / 10s), emits a single JSON object on stdout matching
/// `bridge/tools.c:probe_append_json`: `{ "<name>": { installed, version?,
/// authenticated?, statusOutput? } }`. Requires `sh`, `base64`, `timeout`,
/// `head`, `awk`, `mktemp` — all in the cli-lite rootfs.
const SCAN_TOOLS_SCRIPT: &str = r#"
set -u
TAB=$(printf '\t')
TMP=$(mktemp) || exit 1
trap 'rm -f "$TMP"' EXIT

# Sanitize captured output the way bridge/tools.c:257-262 does: replace
# control bytes < 0x20 except \n \r \t with spaces, then trim trailing
# whitespace. Input is byte-capped by `head -c N` upstream, so O(N).
sanitize() {
  awk 'BEGIN{RS="\0"} {
    s=$0; out=""
    for(i=1;i<=length(s);i++){
      c=substr(s,i,1)
      if (c<" " && c!="\n" && c!="\r" && c!="\t") out=out " "
      else out=out c
    }
    sub(/[ \t\r\n]+$/, "", out)
    printf "%s", out
  }'
}
# JSON-escape stdin → stdout. Only \, ", \n, \r, \t need escaping —
# sanitize already replaced other control bytes with spaces.
json_escape() {
  awk 'BEGIN{RS="\0"} {
    s=$0; out=""
    for(i=1;i<=length(s);i++){
      c=substr(s,i,1)
      if      (c=="\\") out=out "\\\\"
      else if (c=="\"") out=out "\\\""
      else if (c=="\n") out=out "\\n"
      else if (c=="\r") out=out "\\r"
      else if (c=="\t") out=out "\\t"
      else              out=out c
    }
    printf "%s", out
  }'
}

# Run cmd with per-probe timeout, capture up to $3 bytes of combined
# stdout/stderr to $TMP, sanitize, set OUT and EXIT. Tempfile (/tmp tmpfs in
# the jail) caps memory regardless of output volume; `head -c` bounds read.
# EXIT reflects the command (`timeout` returns 124 on kill), not head/awk.
run_capped() {  # $1=timeout_sec  $2=cmd  $3=cap_bytes  → sets OUT, EXIT
  : >"$TMP"
  timeout "$1" sh -c "$2" >"$TMP" 2>&1
  EXIT=$?
  OUT=$(head -c "$3" "$TMP" | sanitize)
}

# POSIX `read` with whitespace IFS collapses consecutive tabs, so a line
# `key\tvb64\t` (empty statusCmd) splits into 2 fields, not 3. Preprocess:
# skip malformed/oversized lines (mirroring bridge/tools.c:parse_entry caps),
# replace empty fields with the sentinel "_" so base64 -d yields "".
printf '{'
first=1
awk -v T="$TAB" 'BEGIN{FS=T; OFS=T} {
  if (NF < 2) next                       # need at least key + version
  if (length($1) == 0 || length($1) > 64) next
  if (length($2) > 1024) next            # b64 cap → decoded < 768
  if (NF >= 3 && length($3) > 1024) next
  for (i=1; i<=3; i++) if ($i == "") $i = "_"
  NF = 3; print
}' | while IFS="$TAB" read -r key vb64 sb64; do
  [ "$key" != "_" ] || continue
  vcmd=$(printf '%s' "$vb64" | base64 -d 2>/dev/null || true)
  scmd=$(printf '%s' "$sb64" | base64 -d 2>/dev/null || true)

  version_out=""; v_exit=1
  status_out="";  s_exit=1
  if [ -n "$vcmd" ]; then run_capped 5  "$vcmd" 100; version_out=$OUT; v_exit=$EXIT; fi
  if [ -n "$scmd" ]; then run_capped 10 "$scmd" 200; status_out=$OUT;  s_exit=$EXIT; fi

  installed=0
  if [ -n "$vcmd" ] && [ "$v_exit" = 0 ] && [ -n "$version_out" ]; then installed=1
  elif [ -z "$vcmd" ] && [ -n "$scmd" ] && [ "$s_exit" = 0 ]; then installed=1
  fi

  [ "$first" = 1 ] || printf ','
  first=0
  printf '"'; printf '%s' "$key" | json_escape; printf '":{'
  if [ "$installed" = 1 ]; then printf '"installed":true'; else printf '"installed":false'; fi
  if [ "$installed" = 1 ] && [ -n "$vcmd" ] && [ "$v_exit" = 0 ] && [ -n "$version_out" ]; then
    printf ',"version":"'; printf '%s' "$version_out" | json_escape; printf '"'
  fi
  if [ "$installed" = 1 ] && [ -n "$scmd" ]; then
    if [ "$s_exit" = 0 ]; then printf ',"authenticated":true'; else printf ',"authenticated":false'; fi
    if [ -n "$status_out" ]; then
      printf ',"statusOutput":"'; printf '%s' "$status_out" | json_escape; printf '"'
    fi
  fi
  printf '}'
done
printf '}'
"#;

fn path_str(p: &Path) -> Result<&str> {
    p.to_str().with_context(|| format!("non-utf8 path: {p:?}"))
}

fn truncate_utf8(mut bytes: Vec<u8>, max: usize) -> (String, bool) {
    let truncated = bytes.len() > max;
    if truncated { bytes.truncate(max); }
    (String::from_utf8_lossy(&bytes).into_owned(), truncated)
}

/// Run a privileged sandbox-manager helper script. Prepends `sudo -n` so
/// it works under either:
///   - prod: sandbox-manager is root → sudo is a no-op fast-path.
///   - dev:  sandbox-manager is `master` → sudoers rule (installed by
///           `systemd/install.sh`) grants passwordless access.
///
/// Returns stdout as String on success; errors include stderr.
async fn run_helper(helper: &Path, args: &[&str]) -> Result<String> {
    let out = Command::new("sudo")
        .arg("-n")
        .arg(helper)
        .args(args)
        .output().await
        .with_context(|| format!("spawn sudo {} {}", helper.display(), args.join(" ")))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("{} {} exited {}: {}",
            helper.display(), args.join(" "), out.status, stderr.trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Loop-mount round-trip tests. Require root (`CAP_SYS_ADMIN` for
/// `mount -o loop`), `mkfs.ext4`, `mount`, `umount`, `mountpoint` on PATH.
/// Skipped by default; run with `sudo -E cargo test -- --ignored lite_`.
#[cfg(test)]
mod tests {
    use super::*;
    use crate::service::user_home::UserHomeStore;

    async fn check_mounted(path: &Path) -> bool {
        Command::new("mountpoint").arg("-q").arg(path)
            .status().await.map(|s| s.success()).unwrap_or(false)
    }

    #[tokio::test]
    #[ignore]
    async fn lite_provision_destroy_round_trip() {
        let tmp = tempfile::tempdir().unwrap();
        let homes = UserHomeStore::new(tmp.path().join("homes"));
        homes.provision("u").await.unwrap();
        let disk = homes.ensure_disk("u", 1).await.unwrap();

        let backend = LiteBackend::new(tmp.path().join("scratch"));
        let id = "sb-test-1";
        backend.provision(id, Some(&disk)).await.unwrap();
        let mnt = backend.home_mountpoint(id);
        assert!(check_mounted(&mnt).await, "provision must leave home mounted");

        // Write a file through the mount; survives across destroy → re-provision.
        let canary = mnt.join("canary.txt");
        tokio::fs::write(&canary, b"hello").await.unwrap();

        backend.destroy(id).await;
        assert!(!check_mounted(&mnt).await, "destroy must umount");
        assert!(!mnt.exists(), "destroy must remove scratch dir");

        // Re-provision a different sandbox id with the same disk: canary survives.
        let id2 = "sb-test-2";
        backend.provision(id2, Some(&disk)).await.unwrap();
        let mnt2 = backend.home_mountpoint(id2);
        let got = tokio::fs::read_to_string(mnt2.join("canary.txt")).await.unwrap();
        assert_eq!(got, "hello", "ext4 contents must persist across mount cycles");
        backend.destroy(id2).await;
    }

    #[tokio::test]
    #[ignore]
    async fn lite_provision_without_disk_is_plain_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let backend = LiteBackend::new(tmp.path().to_path_buf());
        let id = "sb-anon";
        backend.provision(id, None).await.unwrap();
        let mnt = backend.home_mountpoint(id);
        assert!(mnt.is_dir(), "anonymous tier: home is a plain dir");
        assert!(!check_mounted(&mnt).await, "anonymous tier: nothing mounted");
        backend.destroy(id).await;
    }

}
