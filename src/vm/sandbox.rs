//! Sandbox tracking — a Sandbox is a single Firecracker VM instance owned by a user.

use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;
use uuid::Uuid;

use super::size::VmSize;

/// Backend that runs a sandbox.
/// `Vm` = Firecracker microVM (full isolation, networking, persistent).
/// `Lite` = bwrap-jailed exec for our CLIs only (no network, stateless).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SandboxKind {
    #[default]
    Vm,
    Lite,
}

/// Sandbox lifecycle state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SandboxState {
    /// VM is being created
    Creating,
    /// VM is running
    Running,
    /// VM is paused/hibernated
    Paused,
    /// VM is being terminated
    Terminating,
    /// VM has terminated
    Terminated,
    /// VM encountered an error
    Error,
}

/// Sandbox instance — owned by one user (or `anon-*` for unlogged callers).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Sandbox {
    /// Unique sandbox ID
    pub id: String,

    /// User ID (owner)
    pub user_id: String,

    /// Backend kind. Defaults to Vm so old records deserialize unchanged.
    #[serde(default)]
    pub kind: SandboxKind,

    /// Template used
    pub template: String,

    /// VM size tier
    pub size: VmSize,

    /// Current state
    pub state: SandboxState,

    /// Assigned IP address
    pub ip_address: Option<Ipv4Addr>,

    /// TAP device name
    pub tap_device: Option<String>,

    /// Process ID of the Firecracker process
    pub pid: Option<u32>,

    /// Creation timestamp (unix ms)
    pub created_at: u64,

    /// Last activity timestamp (unix ms)
    pub last_activity: u64,

    /// Error message if state is Error
    pub error: Option<String>,
}

impl Sandbox {
    /// Create a new sandbox (state=Creating)
    pub fn new(user_id: String, template: String, size: VmSize) -> Self {
        Self::new_kind(user_id, template, size, SandboxKind::Vm)
    }

    pub fn new_kind(user_id: String, template: String, size: VmSize, kind: SandboxKind) -> Self {
        let now = now_ms();
        Self {
            id: Uuid::new_v4().to_string(),
            user_id,
            kind,
            template,
            size,
            state: SandboxState::Creating,
            ip_address: None,
            tap_device: None,
            pid: None,
            created_at: now,
            last_activity: now,
            error: None,
        }
    }

    /// Update last activity timestamp
    pub fn touch(&mut self) {
        self.last_activity = now_ms();
    }

    /// Check if sandbox is active (running or paused)
    pub fn is_active(&self) -> bool {
        matches!(self.state, SandboxState::Running | SandboxState::Paused)
    }

    /// Get sandbox age in seconds
    pub fn age_seconds(&self) -> u64 {
        (now_ms() - self.created_at) / 1000
    }

    /// Get idle time in seconds
    pub fn idle_seconds(&self) -> u64 {
        (now_ms() - self.last_activity) / 1000
    }

    /// Calculate cost so far
    pub fn cost_so_far(&self) -> f64 {
        let minutes = self.age_seconds() as f64 / 60.0;
        minutes * self.size.cost_per_minute()
    }
}

/// Aggregated stats over all sandboxes (admin view)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SandboxStats {
    /// Total sandboxes ever created
    pub total_created: u64,
    /// Currently active sandboxes (running or paused)
    pub active: u32,
    /// Currently running sandboxes
    pub running: u32,
    /// Currently paused sandboxes
    pub paused: u32,
    /// Total memory allocated (MB)
    pub total_memory_mb: u32,
    /// Total actual memory used (KB, CoW)
    pub actual_memory_kb: u64,
}

/// Per-sandbox runtime metrics — pulled on demand from Firecracker, not stored in inventory.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SandboxMetrics {
    pub cpu_time_ms: u64,
    pub peak_memory_kb: u64,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}
