use serde::{Deserialize, Serialize};

use crate::vm::sandbox::{Sandbox, SandboxKind, SandboxState};
use crate::vm::size::VmSize;

pub use crate::vm::sandbox::SandboxStats;

#[derive(Debug, Deserialize)]
pub struct CreateSandboxRequest {
    /// Required. e.g. "ubuntu-base" (VM) or "cli-lite" (FREE tier).
    pub template: String,
    pub size: Option<VmSize>,
    /// Admin-only: create sandbox on behalf of another user.
    /// Ignored for non-admin callers.
    pub user_id: Option<String>,
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
    pub ws_url: String,
    pub cost_per_minute: f64,
    pub pid: Option<u32>,
    pub error: Option<String>,
    pub created_at: u64,
    pub last_activity: u64,
}

impl From<Sandbox> for SandboxInfo {
    fn from(sandbox: Sandbox) -> Self {
        Self {
            ws_url: format!("/sandbox/{}/tty", sandbox.id),
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
