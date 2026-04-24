use anyhow::{bail, Context, Result};
use std::sync::Arc;

use crate::auth::AuthIdentity;
use crate::backend::BackendClient;
use crate::redis::RedisClient;
use crate::vm::config::TemplateConfig;
use crate::vm::manager::VmManager;

use self::types::{CreateSandboxRequest, SandboxInfo, SandboxList, SandboxStats};

pub mod errors;
pub mod types;

/// TTL for sandbox enroll tokens. Must cover cold boot + network up + redeem
/// round-trip; single-use + short-lived is the security property we want.
const ENROLL_TOKEN_TTL_SEC: u32 = 300;

#[derive(Clone)]
pub struct SandboxService {
    manager: Arc<VmManager>,
    redis: RedisClient,
    backend: Option<BackendClient>,
}

impl SandboxService {
    pub fn new(
        manager: Arc<VmManager>,
        redis: RedisClient,
        backend: Option<BackendClient>,
    ) -> Self {
        Self { manager, redis, backend }
    }

    pub fn redis(&self) -> &RedisClient {
        &self.redis
    }

    /// Create a sandbox owned by the authenticated caller.
    ///
    /// Mints a fresh, short-lived enrollment token via backend admin API
    /// scoped to `identity.user_id`, then injects it into the VM at boot.
    /// The caller's own bearer token never enters the VM.
    pub async fn create_sandbox(
        &self,
        identity: &AuthIdentity,
        req: CreateSandboxRequest,
    ) -> Result<SandboxInfo> {
        // Admins may create on behalf of another user; regular users always
        // create for themselves regardless of what they put in the body.
        let owner_id = match (identity.is_admin(), req.user_id) {
            (true, Some(uid)) => uid,
            _ => identity.user_id.clone(),
        };

        let enroll_token = match &self.backend {
            Some(b) => Some(
                b.mint_enroll_token(&owner_id, Some(ENROLL_TOKEN_TTL_SEC))
                    .await
                    .context("failed to mint enroll token")?
                    .token,
            ),
            None => {
                tracing::warn!(
                    "No backend configured; VM will boot without bridge credentials for user {}",
                    owner_id
                );
                None
            }
        };

        Ok(self
            .manager
            .create_sandbox(owner_id, req.template, req.size, enroll_token, req.ssh_public_key)
            .await?
            .into())
    }

    /// Get a sandbox. User role: 404 if not the owner. Admin: any.
    pub async fn get_sandbox(&self, identity: &AuthIdentity, id: &str) -> Result<Option<SandboxInfo>> {
        let Some(sandbox) = self.manager.get_sandbox(id).await? else { return Ok(None) };
        if !identity.is_admin() && sandbox.user_id != identity.user_id {
            return Ok(None);
        }
        Ok(Some(sandbox.into()))
    }

    /// List caller's sandboxes. Admins can pass `user_id` to query any user (or None for all).
    pub async fn list_sandboxes(&self, identity: &AuthIdentity, user_id: Option<&str>) -> Result<SandboxList> {
        let filter = if identity.is_admin() {
            user_id.map(str::to_string)
        } else {
            Some(identity.user_id.clone())
        };
        Ok(self
            .manager
            .list_sandboxes(filter.as_deref())
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn delete_sandbox(&self, identity: &AuthIdentity, id: &str) -> Result<()> {
        self.assert_owner(identity, id).await?;

        // Refuse to delete the user's last sandbox — they'd lose their only
        // cloud device. Admins bypass this to allow cleanup / support ops.
        if !identity.is_admin() {
            let remaining = self.redis.sandbox_list(Some(&identity.user_id)).await?;
            if remaining.len() <= 1 {
                bail!("cannot delete the user's only sandbox");
            }
        }

        self.manager.delete_sandbox(id).await
    }

    pub async fn pause_sandbox(&self, identity: &AuthIdentity, id: &str) -> Result<()> {
        self.assert_owner(identity, id).await?;
        self.manager.pause_sandbox(id).await
    }

    pub async fn resume_sandbox(&self, identity: &AuthIdentity, id: &str) -> Result<()> {
        self.assert_owner(identity, id).await?;
        self.manager.resume_sandbox(id).await
    }

    pub async fn balloon_sandbox(&self, identity: &AuthIdentity, id: &str, target_mib: u32) -> Result<()> {
        self.assert_owner(identity, id).await?;
        self.manager.balloon_sandbox(id, target_mib).await
    }

    pub async fn stats(&self) -> Result<SandboxStats> {
        self.manager.stats().await
    }

    pub async fn load_template(&self, name: &str, config: &TemplateConfig) -> Result<()> {
        self.manager.load_template(name, config).await
    }

    pub fn list_templates(&self) -> Vec<String> {
        self.manager.list_templates()
    }

    async fn assert_owner(&self, identity: &AuthIdentity, id: &str) -> Result<()> {
        if identity.is_admin() { return Ok(()) }
        match self.manager.get_sandbox(id).await? {
            Some(s) if s.user_id == identity.user_id => Ok(()),
            Some(_) => bail!("forbidden"),
            None => bail!("Sandbox not found"),
        }
    }
}
