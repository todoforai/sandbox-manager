//! VM session tracking

use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;
use uuid::Uuid;

use super::size::VmSize;

/// VM session state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionState {
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

/// VM session information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    /// Unique session ID
    pub id: String,
    
    /// User ID (owner)
    pub user_id: String,
    
    /// Template used
    pub template: String,
    
    /// VM size tier
    pub size: VmSize,
    
    /// Current state
    pub state: SessionState,
    
    /// Assigned IP address
    pub ip_address: Option<Ipv4Addr>,
    
    /// TAP device name
    pub tap_device: Option<String>,
    
    /// KVM VM file descriptor (internal)
    #[serde(skip)]
    pub vm_fd: Option<i32>,
    
    /// Process ID if using Firecracker process
    pub pid: Option<u32>,
    
    /// Creation timestamp (unix ms)
    pub created_at: u64,
    
    /// Last activity timestamp (unix ms)
    pub last_activity: u64,
    
    /// Total CPU time used (ms)
    pub cpu_time_ms: u64,
    
    /// Peak memory usage (KB)
    pub peak_memory_kb: u64,
    
    /// Error message if state is Error
    pub error: Option<String>,
}

impl Session {
    /// Create a new session
    pub fn new(user_id: String, template: String, size: VmSize) -> Self {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
            
        Self {
            id: Uuid::new_v4().to_string(),
            user_id,
            template,
            size,
            state: SessionState::Creating,
            ip_address: None,
            tap_device: None,
            vm_fd: None,
            pid: None,
            created_at: now,
            last_activity: now,
            cpu_time_ms: 0,
            peak_memory_kb: 0,
            error: None,
        }
    }
    
    /// Update last activity timestamp
    pub fn touch(&mut self) {
        self.last_activity = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
    }
    
    /// Check if session is active (running or paused)
    pub fn is_active(&self) -> bool {
        matches!(self.state, SessionState::Running | SessionState::Paused)
    }
    
    /// Get session age in seconds
    pub fn age_seconds(&self) -> u64 {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        (now - self.created_at) / 1000
    }
    
    /// Get idle time in seconds
    pub fn idle_seconds(&self) -> u64 {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        (now - self.last_activity) / 1000
    }
    
    /// Calculate cost so far
    pub fn cost_so_far(&self) -> f64 {
        let minutes = self.age_seconds() as f64 / 60.0;
        minutes * self.size.cost_per_minute()
    }
}

/// Session statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionStats {
    /// Total sessions ever created
    pub total_created: u64,
    /// Currently active sessions
    pub active: u32,
    /// Currently running sessions
    pub running: u32,
    /// Currently paused sessions
    pub paused: u32,
    /// Total memory allocated (MB)
    pub total_memory_mb: u32,
    /// Total actual memory used (KB, CoW)
    pub actual_memory_kb: u64,
}
