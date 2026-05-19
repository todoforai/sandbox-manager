//! Per-user persistent HOME for sandboxes.
//!
//! Each user gets one directory at `<root>/<user_id>/` that **is** their
//! `$HOME` for every sandbox they ever run. No subpaths, no filtering, no
//! schema — the home is the home, bit for bit.
//!
//! - Lite sandboxes bind this directory directly as `/root` (their `$HOME`).
//!   Writes land in the persistent host tree immediately; reads see whatever
//!   the user's tools have produced anywhere else.
//! - VM sandboxes (future) will `rsync` this directory in at boot and back
//!   out at shutdown. Same source of truth, same hands-off policy.
//!
//! Anonymous callers (Better Auth `isAnonymous=1`) get no persistent home
//! — their sandbox is a clean ephemeral scratch (handled by the lite
//! backend's default). The anonymous decision is made in the service
//! layer based on `AuthIdentity::is_anonymous`, not on `user_id`.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

#[derive(Debug, Clone)]
pub struct UserHomeStore {
    /// Root dir. Each user gets `<root>/<user_id>/`.
    root: PathBuf,
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

    /// Best-effort recursive delete. Called when a user account is removed.
    /// Silently ignores invalid `user_id` (no traversal possible).
    pub async fn delete(&self, user_id: &str) {
        if let Ok(dir) = self.home_dir(user_id) {
            let _ = tokio::fs::remove_dir_all(dir).await;
        }
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
}
