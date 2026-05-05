use anyhow::{bail, Context, Result};
use std::sync::Arc;

use crate::auth::AuthIdentity;
use crate::backend::BackendClient;
use crate::recovery::{RecoveryCa, DEFAULT_CERT_TTL_SECS};
use crate::redis::RedisClient;
use crate::vm::config::TemplateConfig;
use crate::vm::lite::ExecOutput;
use crate::vm::manager::VmManager;
use crate::vm::sandbox::{SandboxKind, SandboxState};

use self::types::{CreateSandboxRequest, RecoveryCertResponse, SandboxInfo, SandboxList, SandboxStats};

pub mod errors;
pub mod types;

/// TTL for sandbox enroll tokens. Must cover cold boot + network up + redeem
/// round-trip; single-use + short-lived is the security property we want.
const ENROLL_TOKEN_TTL_SEC: u32 = 300;

#[derive(Clone)]
pub struct SandboxService {
    manager: Arc<VmManager>,
    redis: RedisClient,
    backend: BackendClient,
    recovery_ca: Arc<RecoveryCa>,
}

impl SandboxService {
    pub fn new(
        manager: Arc<VmManager>,
        redis: RedisClient,
        backend: BackendClient,
        recovery_ca: Arc<RecoveryCa>,
    ) -> Self {
        Self { manager, redis, backend, recovery_ca }
    }

    /// Issue a short-lived SSH recovery cert for a sandbox the caller owns.
    /// Returns `(cert_openssh, vsock_uds_path, ttl_secs)`. The caller uses
    /// the cert plus their private key with `fc-vsock-proxy` as ProxyCommand.
    pub async fn issue_recovery_cert(
        &self,
        identity: &AuthIdentity,
        id: &str,
        user_pubkey_openssh: &str,
        ttl_secs: Option<u64>,
    ) -> Result<RecoveryCertResponse> {
        self.assert_owner(identity, id).await?;
        let sandbox = self.manager.get_sandbox(id).await?
            .context("sandbox not found")?;
        if sandbox.kind != SandboxKind::Vm {
            bail!("recovery cert is only available for VM sandboxes");
        }
        if sandbox.state != SandboxState::Running && sandbox.state != SandboxState::Paused {
            bail!("sandbox not in a state that allows recovery (state={:?})", sandbox.state);
        }
        let vsock_path = self.manager.vsock_path_for(id);
        // FC failed to attach the vsock device → no point handing out a cert
        // for a path that will never accept connections. Avoids confusing
        // "Connection refused" downstream.
        if !vsock_path.exists() {
            bail!("recovery vsock UDS missing for sandbox {id}; the VM may be too old (rebuild rootfs) or vsock setup failed");
        }
        let ttl_req = ttl_secs.unwrap_or(DEFAULT_CERT_TTL_SECS);
        let (cert, ttl_eff) = self.recovery_ca.sign_recovery_cert(
            user_pubkey_openssh,
            id,
            &identity.user_id,
            ttl_req,
        )?;
        Ok(RecoveryCertResponse {
            cert,
            vsock_uds_path: vsock_path.display().to_string(),
            // The vsock listener inside the guest runs on port 22 (see /init).
            vsock_port: 22,
            principal: format!("recovery:{id}"),
            ttl_secs: ttl_eff,
        })
    }

    pub fn recovery_ca_authorized_key(&self) -> &str {
        self.recovery_ca.authorized_key_line()
    }

    pub fn redis(&self) -> &RedisClient {
        &self.redis
    }

    pub fn runtime_dir(&self) -> std::path::PathBuf {
        self.manager.runtime_dir()
    }

    /// Create a sandbox. The template determines the backend kind:
    /// - VM templates (e.g. `ubuntu-base`): we mint a short-lived enroll
    ///   token scoped to the owner and inject it into the VM at boot.
    /// - Lite templates (e.g. `cli-lite`, the FREE tier): no enroll token;
    ///   anonymous (`Better Auth isAnonymous`) callers are restricted to these.
    pub async fn create_sandbox(
        &self,
        identity: &AuthIdentity,
        req: CreateSandboxRequest,
    ) -> Result<SandboxInfo> {
        let kind = self.manager.template_kind(&req.template)
            .with_context(|| format!("unknown template: {}", req.template))?;

        if identity.is_anonymous && kind != SandboxKind::Lite {
            bail!("anonymous accounts may only use lite templates");
        }

        let owner_id = match (identity.is_admin(), &req.user_id) {
            (true, Some(uid)) => uid.clone(),
            _ => identity.user_id.clone(),
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

        let mut sandbox = self
            .manager
            .create_sandbox(owner_id.clone(), req.template.clone(), req.size, enroll_token)
            .await?;

        // For Lite sandboxes, materialize a Device row via the standard
        // mint+redeem flow so they appear in the user's device list. VM
        // bridges enroll themselves with the token injected at boot. Best
        // effort: a registration failure does not roll back the sandbox.
        if kind == SandboxKind::Lite && sandbox.state == SandboxState::Running {
            let hostname = format!("sandbox-{}", &sandbox.id[..8]);
            match self.backend.create_lite_sandbox_device(&owner_id, &sandbox.id, &hostname, ENROLL_TOKEN_TTL_SEC).await {
                Ok(device_id) => {
                    sandbox.device_id = Some(device_id.clone());
                    if let Err(e) = self.redis.sandbox_put(&sandbox).await {
                        // Backend row exists but we couldn't remember its id —
                        // it will never be cleaned up by us. Log loudly.
                        tracing::error!("lite sandbox {}: leaked device row {} (redis put failed: {})", sandbox.id, device_id, e);
                    }
                }
                Err(e) => tracing::warn!("lite sandbox {} device registration failed: {}", sandbox.id, e),
            }
        }

        Ok(sandbox.into())
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

        // Read device_id before tearing down so we can clean up the device row.
        // Order: tear down sandbox first, then delete the device row. Reverse
        // order would briefly hide a still-existing sandbox from the UI.
        // VM cleanup-by-sandbox is a separate, unresolved problem (manager
        // never learns the VM's redeemed device id) — tracked elsewhere.
        let pre = self.manager.get_sandbox(id).await.ok().flatten();
        let owner_id = pre.as_ref().map(|s| s.user_id.clone());
        let lite_device_id = pre.as_ref().and_then(|s| s.device_id.clone());

        self.manager.delete_sandbox(id).await?;

        if let (Some(device_id), Some(owner)) = (lite_device_id, owner_id) {
            if let Err(e) = self.backend.delete_device(&owner, &device_id).await {
                tracing::warn!("failed to delete lite sandbox device {}: {}", device_id, e);
            }
        }
        Ok(())
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

    /// Run argv in a lite sandbox. Standard owner check applies.
    pub async fn exec_sandbox(
        &self,
        identity: &AuthIdentity,
        id: &str,
        argv: &[String],
    ) -> Result<ExecOutput> {
        self.assert_owner(identity, id).await?;
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
