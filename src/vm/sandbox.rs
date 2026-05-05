//! Sandbox tracking — a Sandbox is a single Firecracker VM instance owned by a user.

use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;
use std::path::PathBuf;
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

    /// `/proc/<pid>/stat` start_time captured at spawn. Used together with
    /// `pid` on manager restart to detect kernel PID reuse — without this,
    /// we could re-attach to an unrelated process that happens to inherit
    /// the same pid. Always set when `pid` is set; serde-defaulted to keep
    /// old records readable.
    #[serde(default)]
    pub pid_starttime: Option<u64>,

    /// Creation timestamp (unix ms)
    pub created_at: u64,

    /// Last activity timestamp (unix ms)
    pub last_activity: u64,

    /// Error message if state is Error
    pub error: Option<String>,

    /// Backend device row id created for Lite sandboxes so they appear in the
    /// device list. None for Vm sandboxes (their bridge enrolls itself).
    #[serde(default)]
    pub device_id: Option<String>,

    /// Per-sandbox rootfs overlay directory (holds the reflink/copy of the
    /// template's `rootfs.ext4`). VM only. Removed on sandbox delete.
    #[serde(default)]
    pub rootfs_overlay: Option<PathBuf>,
}

impl Sandbox {
    pub fn new_with_id(id: String, user_id: String, template: String, size: VmSize, kind: SandboxKind) -> Self {
        let now = now_ms();
        Self {
            id,
            user_id,
            kind,
            template,
            size,
            state: SandboxState::Creating,
            ip_address: None,
            tap_device: None,
            pid: None,
            pid_starttime: None,
            created_at: now,
            last_activity: now,
            error: None,
            device_id: None,
            rootfs_overlay: None,
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

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// Generate a fresh sandbox id without instantiating a Sandbox. Lets callers
/// reserve the id (e.g. to stamp it onto an enroll token) before the actual
/// VM creation path runs.
pub fn generate_sandbox_id() -> String {
    Uuid::new_v4().to_string()
}
