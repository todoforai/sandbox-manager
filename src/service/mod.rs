use anyhow::{bail, Result};
use std::sync::Arc;

use crate::redis::RedisClient;
use crate::vm::config::TemplateConfig;
use crate::vm::manager::VmManager;

use self::types::{CreateSandboxRequest, SandboxInfo, SandboxList, SandboxStats};

pub mod errors;
pub mod types;

#[derive(Clone)]
pub struct SandboxService {
    manager: Arc<VmManager>,
    redis: Option<RedisClient>,
}

impl SandboxService {
    pub fn new(manager: Arc<VmManager>, redis: Option<RedisClient>) -> Self {
        Self { manager, redis }
    }

    /// Validate that the token resolves to the claimed user_id.
    /// If Redis is not configured, auth is skipped (dev/internal mode).
    async fn auth(&self, user_id: &str, token: Option<&str>) -> Result<()> {
        let Some(ref redis) = self.redis else { return Ok(()) };
        let Some(token) = token else { bail!("auth token required") };
        let resolved = redis.resolve_token(token).await?;
        match resolved {
            Some(uid) if uid == user_id => Ok(()),
            Some(_) => bail!("token does not match user_id"),
            None => bail!("invalid token"),
        }
    }

    pub async fn create_sandbox(&self, req: CreateSandboxRequest) -> Result<SandboxInfo> {
        self.auth(&req.user_id, req.edge_token.as_deref()).await?;
        Ok(self
            .manager
            .create_sandbox(req.user_id, req.template, req.size, req.edge_token)
            .await?
            .into())
    }

    pub fn get_sandbox(&self, id: &str) -> Option<SandboxInfo> {
        self.manager.get_sandbox(id).map(Into::into)
    }

    pub fn list_sandboxes(&self, user_id: Option<&str>) -> SandboxList {
        self.manager
            .list_sandboxes(user_id)
            .into_iter()
            .map(Into::into)
            .collect()
    }

    pub async fn delete_sandbox(&self, id: &str) -> Result<()> {
        self.manager.delete_sandbox(id).await
    }

    pub async fn pause_sandbox(&self, id: &str) -> Result<()> {
        self.manager.pause_sandbox(id).await
    }

    pub async fn resume_sandbox(&self, id: &str) -> Result<()> {
        self.manager.resume_sandbox(id).await
    }

    pub fn stats(&self) -> SandboxStats {
        self.manager.stats()
    }

    pub async fn load_template(&self, name: &str, config: &TemplateConfig) -> Result<()> {
        self.manager.load_template(name, config).await
    }

    pub fn list_templates(&self) -> Vec<String> {
        self.manager.list_templates()
    }


}
