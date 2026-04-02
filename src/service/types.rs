use serde::{Deserialize, Serialize};

use crate::vm::session::{Session, SessionState, SessionStats};
use crate::vm::size::VmSize;

#[derive(Debug, Deserialize)]
pub struct CreateSandboxRequest {
    pub user_id: String,
    pub template: Option<String>,
    pub size: Option<VmSize>,
    pub edge_token: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SandboxInfo {
    pub id: String,
    pub user_id: String,
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

impl From<Session> for SandboxInfo {
    fn from(session: Session) -> Self {
        Self {
            ws_url: format!("/sandbox/{}/tty", session.id),
            cost_per_minute: session.size.cost_per_minute(),
            ip_address: session.ip_address.map(|ip| ip.to_string()),
            state: state_name(session.state).to_string(),
            id: session.id,
            user_id: session.user_id,
            template: session.template,
            size: session.size,
            pid: session.pid,
            error: session.error,
            created_at: session.created_at,
            last_activity: session.last_activity,
        }
    }
}

pub fn state_name(state: SessionState) -> &'static str {
    match state {
        SessionState::Creating => "creating",
        SessionState::Running => "running",
        SessionState::Paused => "paused",
        SessionState::Terminating => "terminating",
        SessionState::Terminated => "terminated",
        SessionState::Error => "error",
    }
}

pub type SandboxList = Vec<SandboxInfo>;
pub type SandboxStats = SessionStats;
