//! Per-user persistent HOME for lite sandboxes.
//!
//! Each user gets a directory tree at `<root>/<user_id>/` that holds the
//! parts of `$HOME` we want to share across all of their sandbox executions
//! — primarily `~/.config/` and `~/.local/share/`, which between them
//! contain credential files for almost every CLI tool we ship.
//!
//! Lite sandboxes set `HOME=/work`, so we bind-mount these host dirs onto
//! `/work/.config` and `/work/.local/share`. A tool inside the sandbox sees
//! a normal home dir and reads/writes its credentials as usual; the data
//! actually lands in the user's persistent host tree and survives across
//! sandbox lifecycles.
//!
//! Anonymous / unauthenticated callers (`user_id` empty) get no binds —
//! their sandbox is a clean ephemeral scratch.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::vm::lite::ExecBinds;

/// Subpaths under each user's home that we expose to their sandboxes.
/// Order matters only for readability — they're independent mounts.
const SHARED_SUBPATHS: &[&str] = &[".config", ".local/share"];

#[derive(Debug, Clone)]
pub struct UserHomeStore {
    /// Root dir. Each user gets `<root>/<user_id>/`.
    root: PathBuf,
}

impl UserHomeStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// Host path of a user's home tree. Validates `user_id` is a safe single
    /// path segment — no `/`, no `..`, no empties, no surprises. Admin-set
    /// IDs from `CreateSandboxRequest.user_id` must not escape `root`.
    pub fn home_dir(&self, user_id: &str) -> Result<PathBuf> {
        validate_user_id(user_id)?;
        Ok(self.root.join(user_id))
    }

    /// Create the user's home tree if missing. Idempotent. Safe to call
    /// on every sandbox exec. Errors for invalid/empty `user_id`.
    pub async fn provision(&self, user_id: &str) -> Result<PathBuf> {
        let dir = self.home_dir(user_id)?;
        for sub in SHARED_SUBPATHS {
            tokio::fs::create_dir_all(dir.join(sub)).await
                .with_context(|| format!("create {sub} in {dir:?}"))?;
        }
        Ok(dir)
    }

    /// Best-effort recursive delete. Called when a user account is removed.
    /// Silently ignores invalid `user_id` (no traversal possible).
    pub async fn delete(&self, user_id: &str) {
        if let Ok(dir) = self.home_dir(user_id) {
            let _ = tokio::fs::remove_dir_all(dir).await;
        }
    }

    /// Build the bind list that exposes this user's persistent home to a
    /// sandbox. Empty / invalid `user_id` → no binds (anonymous tier).
    pub fn binds_for(&self, user_id: &str) -> ExecBinds {
        let mut out = ExecBinds::default();
        let Ok(home) = self.home_dir(user_id) else { return out };
        for sub in SHARED_SUBPATHS {
            out.rw.push((home.join(sub), format!("/work/{sub}")));
        }
        out
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
    async fn provision_creates_subpaths() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        let home = store.provision("alice").await.unwrap();
        assert!(home.join(".config").is_dir());
        assert!(home.join(".local/share").is_dir());
    }

    #[tokio::test]
    async fn provision_is_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        store.provision("bob").await.unwrap();
        store.provision("bob").await.unwrap();
        assert!(store.home_dir("bob").unwrap().join(".config").is_dir());
    }

    #[test]
    fn binds_for_user_maps_subpaths() {
        let store = UserHomeStore::new(PathBuf::from("/srv/homes"));
        let b = store.binds_for("alice");
        assert!(b.ro.is_empty());
        let rw: Vec<_> = b.rw.iter().map(|(h, s)| (h.to_str().unwrap(), s.as_str())).collect();
        assert_eq!(rw, vec![
            ("/srv/homes/alice/.config", "/work/.config"),
            ("/srv/homes/alice/.local/share", "/work/.local/share"),
        ]);
    }

    #[test]
    fn binds_for_anonymous_is_empty() {
        let store = UserHomeStore::new(PathBuf::from("/srv/homes"));
        let b = store.binds_for("");
        assert!(b.ro.is_empty() && b.rw.is_empty());
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

    #[test]
    fn binds_for_invalid_id_is_empty() {
        let store = UserHomeStore::new(PathBuf::from("/srv/homes"));
        for bad in ["..", "a/b", "/etc"] {
            let b = store.binds_for(bad);
            assert!(b.ro.is_empty() && b.rw.is_empty(), "should refuse {bad:?}");
        }
    }

    #[tokio::test]
    async fn provision_rejects_traversal() {
        let tmp = tempfile::tempdir().unwrap();
        let store = UserHomeStore::new(tmp.path().to_path_buf());
        assert!(store.provision("../escape").await.is_err());
        // Confirm nothing was created at the parent of root.
        let parent = tmp.path().parent().unwrap();
        assert!(!parent.join("escape").exists());
    }
}
