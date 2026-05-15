use serde::{Deserialize, Serialize};

use crate::vm::config::TemplateConfig;
use crate::vm::sandbox::{Sandbox, SandboxKind, SandboxState};
use crate::vm::size::VmSize;

pub use crate::vm::sandbox::SandboxStats;

/// Default kernel cmdline for templates created via the API. Mirrors the
/// auto-discovery default in `vm::manager::discover_templates`.
pub const DEFAULT_BOOT_ARGS: &str =
    "console=ttyS0 reboot=k panic=1 pci=off init=/init";

#[derive(Debug, Deserialize)]
pub struct CreateSandboxRequest {
    /// Required. e.g. "ubuntu-base" (VM) or "cli-lite" (FREE tier).
    pub template: String,
    pub size: Option<VmSize>,
    /// Admin-only: create sandbox on behalf of another user.
    /// Ignored for non-admin callers.
    pub user_id: Option<String>,
}

/// Shared template-creation payload — used by both the REST and Noise adapters.
/// `name` is taken from the request path / call args, not the body.
#[derive(Debug, Deserialize)]
pub struct CreateTemplateRequest {
    pub kernel_path: String,
    pub rootfs_path: String,
    pub boot_args: Option<String>,
    pub description: Option<String>,
    pub packages: Option<Vec<String>>,
}

impl CreateTemplateRequest {
    pub fn into_config(self, name: String) -> TemplateConfig {
        TemplateConfig {
            name,
            kernel_path: self.kernel_path.into(),
            rootfs_path: self.rootfs_path.into(),
            boot_args: self.boot_args.unwrap_or_else(|| DEFAULT_BOOT_ARGS.into()),
            description: self.description.unwrap_or_default(),
            packages: self.packages.unwrap_or_default(),
            ..Default::default()
        }
    }
}

#[derive(Debug, Serialize)]
pub struct SandboxInfo {
    pub id: String,
    pub user_id: String,
    pub kind: SandboxKind,
    pub template: String,
    pub size: VmSize,
    pub state: String,
    pub ip_address: Option<String>,
    pub cost_per_minute: f64,
    pub pid: Option<u32>,
    pub error: Option<String>,
    /// Backend Device row this sandbox's bridge enrolled as. Set at create
    /// time for Lite, after redeem (via `attach-device`) for VM.
    pub device_id: Option<String>,
    pub created_at: u64,
    pub last_activity: u64,
}

impl From<Sandbox> for SandboxInfo {
    fn from(sandbox: Sandbox) -> Self {
        Self {
            cost_per_minute: sandbox.size.cost_per_minute(),
            ip_address: sandbox.ip_address.map(|ip| ip.to_string()),
            state: state_name(sandbox.state).to_string(),
            id: sandbox.id,
            user_id: sandbox.user_id,
            kind: sandbox.kind,
            template: sandbox.template,
            size: sandbox.size,
            pid: sandbox.pid,
            error: sandbox.error,
            device_id: sandbox.device_id,
            created_at: sandbox.created_at,
            last_activity: sandbox.last_activity,
        }
    }
}

pub fn state_name(state: SandboxState) -> &'static str {
    match state {
        SandboxState::Creating => "creating",
        SandboxState::Running => "running",
        SandboxState::Paused => "paused",
        SandboxState::Terminating => "terminating",
        SandboxState::Terminated => "terminated",
        SandboxState::Error => "error",
    }
}

pub type SandboxList = Vec<SandboxInfo>;

/// Response for `POST /sandbox/:id/recovery-cert`.
#[derive(Debug, Serialize)]
pub struct RecoveryCertResponse {
    /// OpenSSH-format user certificate (single line). Pair with the user's
    /// private key in `ssh -i <key> -o CertificateFile=<this>`.
    pub cert: String,
    /// Host UDS for the VM's vsock device. Use as
    /// `ProxyCommand="fc-vsock-proxy <uds> <port>"`.
    pub vsock_uds_path: String,
    pub vsock_port: u32,
    /// SSH cert principal (informational). Cert is locked to this; matches
    /// the guest's `/etc/ssh/auth_principals/recovery`.
    pub principal: String,
    pub ttl_secs: u64,
}
