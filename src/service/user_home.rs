//! Per-user persistent HOME for sandboxes.
//!
//! Each user gets one directory at `<root>/<user_id>/` that **is** their
//! `$HOME` for every sandbox they run. Lite sandboxes bind this directory
//! directly as `/root` on every exec.
//!
//! ## Exclusivity
//!
//! At most one sandbox per user may "hold" the home directory at any time.
//! Enforced by a per-user `flock(LOCK_EX|LOCK_NB)` on `<root>/<user_id>/.lock`,
//! acquired in [`UserHomeStore::acquire_lock`]. The returned `OwnedFd` lives
//! on the in-memory [`VmManager`] state for the sandbox; dropping it (sandbox
//! delete, manager process exit) releases the kernel lock automatically.
//!
//! Anonymous callers (Better Auth `isAnonymous=1`) get no persistent home —
//! their sandbox is a clean ephemeral scratch (handled by the lite backend's
//! default). The anonymous decision is made in the service layer based on
//! `AuthIdentity::is_anonymous`, not on `user_id`.

use std::os::fd::{AsRawFd, OwnedFd};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

#[derive(Debug, Clone)]
pub struct UserHomeStore {
    /// Root dir. Each user gets `<root>/<user_id>/`.
    root: PathBuf,
}

/// Result of trying to acquire a user-home lock. `Busy` means another
/// sandbox of this user already holds the home; caller must evict it
/// (delete the existing sandbox) and retry.
pub enum LockOutcome {
    Acquired(OwnedFd),
    Busy,
}

impl UserHomeStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// Host path of a user's home dir. Validates `user_id` is a safe single
    /// path segment — no `/`, no `..`, no empties, no surprises. Admin-set
    /// IDs from `CreateSandboxRequest.user_id` must not escape `root`.
    pub fn home_dir(&self, user_id: &str) -> Result<PathBuf> {
        validate_user_id(user_id)?;
        Ok(self.root.join(user_id))
    }

    /// Create the user's home dir if missing. Idempotent. Safe to call on
    /// every sandbox exec. Errors for invalid/empty `user_id`.
    pub async fn provision(&self, user_id: &str) -> Result<PathBuf> {
        let dir = self.home_dir(user_id)?;
        tokio::fs::create_dir_all(&dir).await
            .with_context(|| format!("create user home {dir:?}"))?;
        Ok(dir)
    }

    /// Try to take exclusive ownership of the user's home for a sandbox.
    /// Non-blocking: returns `Busy` immediately if another sandbox-manager-
    /// owned fd already holds the lock. Caller must call [`Self::provision`]
    /// first so the lock file's parent dir exists.
    ///
    /// The returned `OwnedFd` must outlive the sandbox; dropping it releases
    /// the kernel lock (also released automatically on process death).
    pub fn acquire_lock(&self, user_id: &str) -> Result<LockOutcome> {
        let lock_path = self.home_dir(user_id)?.join(".lock");
        let file = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .with_context(|| format!("open lock file {lock_path:?}"))?;
        let fd: OwnedFd = file.into();
        // flock(LOCK_EX|LOCK_NB): exclusive, non-blocking. EWOULDBLOCK ==
        // another sandbox-manager fd holds it. Lock is fd-scoped: closing
        // the fd (or the process dying) releases it.
        let rc = unsafe { libc::flock(fd.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc == 0 {
            return Ok(LockOutcome::Acquired(fd));
        }
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EWOULDBLOCK) {
            return Ok(LockOutcome::Busy);
        }
        Err(err).with_context(|| format!("flock {lock_path:?}"))
    }

    /// Best-effort recursive delete. Called when a user account is removed.
    /// Silently ignores invalid `user_id` (no traversal possible).
    pub async fn delete(&self, user_id: &str) {
        if let Ok(dir) = self.home_dir(user_id) {
            let _ = tokio::fs::remove_dir_all(dir).await;
        }
    }

    /// Path of the user's persistent `$HOME` disk image. The file at this
    /// path is the single source of truth for the user's home bytes: VM
    /// sandboxes attach it as a virtio-blk drive; Lite sandboxes loop-mount
    /// it on the host. Caller must have provisioned the parent dir.
    pub fn disk_path(&self, user_id: &str) -> Result<PathBuf> {
        Ok(self.home_dir(user_id)?.join("home.img"))
    }

    /// Ensure the user's `$HOME` disk image exists and is formatted. Creates
    /// a sparse `size_gib`-sized raw file and `mkfs.ext4`s it on first call;
    /// returns the path. Idempotent: if the file already exists, returns it
    /// unchanged (no resize, no reformat).
    ///
    /// The image is **never re-formatted** once it exists — that would lose
    /// every byte the user has accumulated. If the file looks corrupt the
    /// operator must delete it manually.
    pub async fn ensure_disk(&self, user_id: &str, size_gib: u64) -> Result<PathBuf> {
        let path = self.disk_path(user_id)?;
        if path.exists() {
            return Ok(path);
        }
        // Sparse allocation: on-disk usage is what the guest writes, not
        // size_gib. A fresh 50G ext4 image is ~5MB on disk.
        let size_bytes = size_gib.checked_mul(1024 * 1024 * 1024)
            .context("size_gib overflow")?;
        let f = tokio::fs::File::create(&path).await
            .with_context(|| format!("create disk {path:?}"))?;
        f.set_len(size_bytes).await
            .with_context(|| format!("truncate disk {path:?} to {size_gib}G"))?;
        drop(f);

        // mkfs.ext4 -F: don't prompt; we know the file is fresh and empty.
        // -E lazy_itable_init=1,lazy_journal_init=1 keeps mkfs near-instant
        // on large sparse files (default would zero the inode table eagerly).
        let status = tokio::process::Command::new("mkfs.ext4")
            .args(["-F", "-E", "lazy_itable_init=1,lazy_journal_init=1"])
            .arg(&path)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status().await
            .with_context(|| format!("spawn mkfs.ext4 {path:?}"))?;
        if !status.success() {
            // Don't leave a half-formatted file behind to confuse the next call.
            let _ = tokio::fs::remove_file(&path).await;
            anyhow::bail!("mkfs.ext4 {path:?} exited {status}");
        }
        tracing::info!("created home disk {} ({}G sparse)", path.display(), size_gib);
        Ok(path)
    }
}

/// Reject anything that could escape `root` via the filesystem join, or
/// that depends on the host's user-namespace state. We don't try to be
/// clever — the only valid IDs are non-empty ASCII alnum + `_-.`, with
/// no `..` segment.
fn validate_user_id(user_id: &str) -> Result<()> {
    if user_id.is_empty() {
        anyhow::bail!("user_id is empty");
    }
    if user_id == "." || user_id == ".." {
        anyhow::bail!("user_id is a path traversal sentinel");
    }
    if user_id.len() > 128 {
        anyhow::bail!("user_id too long");
    }
    let ok = user_id.bytes().all(|b| {
        b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'.'
    });
    if !ok {
        anyhow::bail!("user_id has invalid characters (allow [A-Za-z0-9_.-])");
    }
    Ok(())
}

/// Default root when `USER_HOMES_DIR` env is unset: alongside the existing
/// overlays / scratch tree. Caller is the manager init code.
///
/// Scope: this directory lives on the sandbox-manager host and holds each
/// user's persistent sandbox HOME (dotfiles, CLI auth state, agent-created
/// files). It is deliberately separate from `storage-manager`'s
/// `<DATA_DIR>/userfiles/` on the api host — two disks, two hosts, no
/// shared mount. The sandbox HOME is reached only via terminal / SSH /
/// in-sandbox agent. The web UI's "Files" area is a different world.
pub fn default_root(overlays_dir: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("USER_HOMES_DIR") {
        return PathBuf::from(p);
    }
    overlays_dir.join("user-homes")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn provision_creates_user_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        let home = store.provision("alice").await.unwrap();
        assert!(home.is_dir());
        assert_eq!(home, tmp.path().join("alice"));
    }

    #[tokio::test]
    async fn provision_is_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        store.provision("bob").await.unwrap();
        store.provision("bob").await.unwrap();
        assert!(store.home_dir("bob").unwrap().is_dir());
    }

    #[tokio::test]
    async fn delete_removes_user_home() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        store.provision("carol").await.unwrap();
        assert!(store.home_dir("carol").unwrap().exists());
        store.delete("carol").await;
        assert!(!store.home_dir("carol").unwrap().exists());
    }

    #[test]
    fn validate_rejects_traversal_and_separators() {
        for bad in ["", ".", "..", "../etc", "a/b", "a\\b", "alice/", "/alice", "name with space"] {
            assert!(validate_user_id(bad).is_err(), "should reject {bad:?}");
        }
    }

    #[test]
    fn validate_accepts_safe_ids() {
        for good in ["alice", "user_42", "a-b", "USER.1", "0123456789abcdef"] {
            assert!(validate_user_id(good).is_ok(), "should accept {good:?}");
        }
    }

    #[tokio::test]
    async fn provision_rejects_traversal() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        assert!(store.provision("../escape").await.is_err());
        let parent = tmp.path().parent().unwrap();
        assert!(!parent.join("escape").exists());
    }

    #[tokio::test]
    async fn lock_is_exclusive() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        store.provision("dave").await.unwrap();
        let LockOutcome::Acquired(fd1) = store.acquire_lock("dave").unwrap() else { panic!("expected Acquired") };
        // Second try must report Busy.
        assert!(matches!(store.acquire_lock("dave").unwrap(), LockOutcome::Busy));
        // Drop the first fd → lock released → next acquire succeeds.
        drop(fd1);
        assert!(matches!(store.acquire_lock("dave").unwrap(), LockOutcome::Acquired(_)));
    }

    #[tokio::test]
    async fn lock_is_per_user() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        store.provision("eve").await.unwrap();
        store.provision("frank").await.unwrap();
        let _e = store.acquire_lock("eve").unwrap();
        // Different user's lock is independent.
        assert!(matches!(store.acquire_lock("frank").unwrap(), LockOutcome::Acquired(_)));
    }

    /// Requires `mkfs.ext4` on PATH; not run by default to keep `cargo test`
    /// hermetic. Invoke with `cargo test -- --ignored ensure_disk`.
    #[tokio::test]
    #[ignore]
    async fn ensure_disk_creates_sparse_image() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        store.provision("gina").await.unwrap();
        let path = store.ensure_disk("gina", 4).await.unwrap();
        assert!(path.is_file(), "home.img must exist");

        let meta = std::fs::metadata(&path).unwrap();
        assert_eq!(meta.len(), 4 * 1024 * 1024 * 1024, "logical size = 4 GiB");
        // Sparse: physical blocks (512-byte units) should be far smaller
        // than logical length. A fresh lazy-init ext4 in 4G is <50 MiB on
        // disk; pick a generous ceiling to keep the test stable.
        use std::os::unix::fs::MetadataExt;
        let physical_bytes = meta.blocks() * 512;
        assert!(
            physical_bytes < 200 * 1024 * 1024,
            "expected sparse <200MiB, got {physical_bytes} bytes",
        );
    }

    #[tokio::test]
    #[ignore]
    async fn ensure_disk_is_idempotent_and_preserves_bytes() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        store.provision("hank").await.unwrap();
        let p1 = store.ensure_disk("hank", 4).await.unwrap();
        // Mutate one byte inside the image — second call must NOT reformat
        // (would destroy user data). We poke a byte well past the ext4
        // superblock so any reformat is guaranteed to overwrite it.
        use std::io::{Seek, SeekFrom, Write};
        {
            let mut f = std::fs::OpenOptions::new().write(true).open(&p1).unwrap();
            f.seek(SeekFrom::Start(2 * 1024 * 1024)).unwrap(); // 2 MiB in
            f.write_all(b"DO-NOT-WIPE").unwrap();
        }
        let p2 = store.ensure_disk("hank", 4).await.unwrap();
        assert_eq!(p1, p2);
        let mut f = std::fs::File::open(&p2).unwrap();
        f.seek(SeekFrom::Start(2 * 1024 * 1024)).unwrap();
        let mut buf = [0u8; 11];
        use std::io::Read;
        f.read_exact(&mut buf).unwrap();
        assert_eq!(&buf, b"DO-NOT-WIPE", "ensure_disk reformatted an existing image");
    }
}
