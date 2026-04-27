use anyhow::{bail, Context, Result};
use std::sync::Arc;

use crate::auth::AuthIdentity;
use crate::backend::BackendClient;
use crate::redis::RedisClient;
use crate::vm::config::TemplateConfig;
use crate::vm::lite::ExecOutput;
use crate::vm::manager::VmManager;
use crate::vm::sandbox::SandboxKind;

use self::types::{CreateSandboxRequest, SandboxInfo, SandboxList, SandboxStats};

pub mod errors;
pub mod types;

/// Templates an unauthenticated caller is allowed to spawn.
const ANON_ALLOWED_TEMPLATES: &[&str] = &["cli-lite"];

/// TTL for sandbox enroll tokens. Must cover cold boot + network up + redeem
/// round-trip; single-use + short-lived is the security property we want.
const ENROLL_TOKEN_TTL_SEC: u32 = 300;

#[derive(Clone)]
pub struct SandboxService {
    manager: Arc<VmManager>,
    redis: RedisClient,
    backend: BackendClient,
}

impl SandboxService {
    pub fn new(
        manager: Arc<VmManager>,
        redis: RedisClient,
        backend: BackendClient,
    ) -> Self {
        Self { manager, redis, backend }
    }

    pub fn redis(&self) -> &RedisClient {
        &self.redis
    }

    /// Create a sandbox. The template determines the backend kind:
    /// - VM templates (e.g. `ubuntu-base`): authenticated callers only;
    ///   we mint a short-lived enroll token and inject it at boot.
    /// - Lite templates (e.g. `cli-lite`, the FREE tier): allow-listed
    ///   templates may be created anonymously; no enroll token.
    pub async fn create_sandbox(
        &self,
        identity: Option<&AuthIdentity>,
        req: CreateSandboxRequest,
    ) -> Result<SandboxInfo> {
        let kind = self.manager.template_kind(&req.template)
            .with_context(|| format!("unknown template: {}", req.template))?;

        let owner_id = match (identity, &req.user_id) {
            (Some(id), Some(uid)) if id.is_admin() => uid.clone(),
            (Some(id), _) => id.user_id.clone(),
            (None, _) => {
                if kind != SandboxKind::Lite {
                    bail!("authentication required for template '{}'", req.template);
                }
                if !ANON_ALLOWED_TEMPLATES.contains(&req.template.as_str()) {
                    bail!("template '{}' not available without authentication", req.template);
                }
                format!("anon-{}", &uuid::Uuid::new_v4().to_string()[..8])
            }
        };

        let enroll_token = if kind == SandboxKind::Vm {
            Some(self.backend
                .mint_enroll_token(&owner_id, Some(ENROLL_TOKEN_TTL_SEC))
                .await
                .context("failed to mint enroll token")?
                .token)
        } else {
            None
        };

        Ok(self
            .manager
            .create_sandbox(owner_id, req.template, req.size, enroll_token)
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

        // Refuse to delete the user's last *VM* sandbox — they'd lose their
        // only cloud device. Lite sandboxes are throwaway, no such guard.
        // Admins bypass this entirely.
        if !identity.is_admin() {
            let remaining = self.redis.sandbox_list(Some(&identity.user_id)).await?;
            let vm_remaining = remaining.iter().filter(|s| s.kind == SandboxKind::Vm).count();
            let target_is_vm = remaining.iter().find(|s| s.id == id).map(|s| s.kind == SandboxKind::Vm).unwrap_or(false);
            if target_is_vm && vm_remaining <= 1 {
                bail!("cannot delete the user's only VM sandbox");
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

    /// Run argv in a lite sandbox. Anonymous callers may exec on `anon-*`
    /// sandboxes (we identify them by the matching prefix on the user_id).
    pub async fn exec_sandbox(
        &self,
        identity: Option<&AuthIdentity>,
        id: &str,
        argv: &[String],
    ) -> Result<ExecOutput> {
        let sandbox = self.manager.get_sandbox(id).await?
            .context("Sandbox not found")?;
        let allowed = match identity {
            Some(id) => id.is_admin() || id.user_id == sandbox.user_id,
            None => sandbox.user_id.starts_with("anon-"),
        };
        if !allowed { bail!("forbidden"); }
        self.manager.exec_lite(id, argv).await
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
