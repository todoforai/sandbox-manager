//! VM size tiers - small, medium, large, custom
//! 
//! Each tier defines resource limits for the VM.
//! CoW means base memory is shared - only dirty pages count against the limit.

use serde::{Deserialize, Serialize};

/// VM size tier
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum VmSize {
    /// Minimal: 64MB RAM, 0.5 vCPU
    /// Good for: simple scripts, quick tasks
    /// Cost: ~$0.005/min
    Small,
    
    /// Standard: 128MB RAM, 1 vCPU  
    /// Good for: most agent tasks, npm install, git operations
    /// Cost: ~$0.01/min
    #[default]
    Medium,
    
    /// Power: 256MB RAM, 2 vCPU
    /// Good for: builds, heavy computation, multiple processes
    /// Cost: ~$0.02/min
    Large,
    
    /// Maximum: 512MB RAM, 4 vCPU
    /// Good for: large builds, ML inference, memory-intensive tasks
    /// Cost: ~$0.04/min
    XLarge,
    
    /// Custom configuration
    Custom {
        memory_mb: u32,
        vcpu_count: u8,
    },
}

impl VmSize {
    /// Memory in megabytes
    pub fn memory_mb(&self) -> u32 {
        match self {
            VmSize::Small => 128,
            VmSize::Medium => 256,
            VmSize::Large => 512,
            VmSize::XLarge => 1024,
            VmSize::Custom { memory_mb, .. } => *memory_mb,
        }
    }
    
    /// Number of virtual CPUs
    pub fn vcpu_count(&self) -> u8 {
        match self {
            VmSize::Small => 1,
            VmSize::Medium => 1,
            VmSize::Large => 2,
            VmSize::XLarge => 4,
            VmSize::Custom { vcpu_count, .. } => *vcpu_count,
        }
    }
    
    /// Cost per minute in USD
    pub fn cost_per_minute(&self) -> f64 {
        match self {
            VmSize::Small => 0.005,
            VmSize::Medium => 0.01,
            VmSize::Large => 0.02,
            VmSize::XLarge => 0.04,
            VmSize::Custom { memory_mb, vcpu_count } => {
                // Base cost: $0.00004/MB/min + $0.005/vCPU/min
                (*memory_mb as f64 * 0.00004) + (*vcpu_count as f64 * 0.005)
            }
        }
    }
    
    /// Actual memory used (CoW = only dirty pages)
    /// This is an estimate - actual varies by workload
    pub fn estimated_actual_memory_kb(&self) -> u32 {
        match self {
            // CoW: ~1-5% of allocated memory is typically dirty
            VmSize::Small => 1000,   // ~1MB dirty pages
            VmSize::Medium => 2000,  // ~2MB dirty pages  
            VmSize::Large => 4000,   // ~4MB dirty pages
            VmSize::XLarge => 8000,  // ~8MB dirty pages
            VmSize::Custom { memory_mb, .. } => memory_mb * 10, // ~1% estimate
        }
    }
    
    /// Human-readable description
    pub fn description(&self) -> &'static str {
        match self {
            VmSize::Small => "Small (64MB, 1 vCPU) - simple scripts",
            VmSize::Medium => "Medium (128MB, 1 vCPU) - standard tasks",
            VmSize::Large => "Large (256MB, 2 vCPU) - builds & computation",
            VmSize::XLarge => "XLarge (512MB, 4 vCPU) - heavy workloads",
            VmSize::Custom { .. } => "Custom configuration",
        }
    }
    
    /// Parse from string
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "small" | "s" | "sm" => Some(VmSize::Small),
            "medium" | "m" | "md" | "standard" => Some(VmSize::Medium),
            "large" | "l" | "lg" => Some(VmSize::Large),
            "xlarge" | "xl" | "x-large" | "extra-large" => Some(VmSize::XLarge),
            _ => None,
        }
    }
}

/// VM size limits for a user/plan
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SizeLimits {
    /// Maximum allowed size tier
    pub max_size: VmSize,
    /// Maximum concurrent VMs
    pub max_concurrent: u32,
    /// Maximum total memory across all VMs (MB)
    pub max_total_memory_mb: u32,
}

impl Default for SizeLimits {
    fn default() -> Self {
        Self {
            max_size: VmSize::Medium,
            max_concurrent: 3,
            max_total_memory_mb: 512,
        }
    }
}

impl SizeLimits {
    /// Hobby plan limits
    pub fn hobby() -> Self {
        Self {
            max_size: VmSize::Small,
            max_concurrent: 1,
            max_total_memory_mb: 64,
        }
    }
    
    /// Starter plan limits
    pub fn starter() -> Self {
        Self {
            max_size: VmSize::Medium,
            max_concurrent: 3,
            max_total_memory_mb: 384,
        }
    }
    
    /// Pro plan limits
    pub fn pro() -> Self {
        Self {
            max_size: VmSize::Large,
            max_concurrent: 10,
            max_total_memory_mb: 2048,
        }
    }
    
    /// Ultra plan limits
    pub fn ultra() -> Self {
        Self {
            max_size: VmSize::XLarge,
            max_concurrent: 50,
            max_total_memory_mb: 16384,
        }
    }
    
    /// Check if a size is allowed
    pub fn allows_size(&self, size: &VmSize) -> bool {
        size.memory_mb() <= self.max_size.memory_mb()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_size_tiers() {
        assert_eq!(VmSize::Small.memory_mb(), 128);
        assert_eq!(VmSize::Medium.memory_mb(), 256);
        assert_eq!(VmSize::Large.memory_mb(), 512);
        assert_eq!(VmSize::XLarge.memory_mb(), 1024);
    }
    
    #[test]
    fn test_custom_size() {
        let custom = VmSize::Custom { memory_mb: 192, vcpu_count: 2 };
        assert_eq!(custom.memory_mb(), 192);
        assert_eq!(custom.vcpu_count(), 2);
    }
    
    #[test]
    fn test_cost_calculation() {
        assert!(VmSize::Small.cost_per_minute() < VmSize::Medium.cost_per_minute());
        assert!(VmSize::Medium.cost_per_minute() < VmSize::Large.cost_per_minute());
    }
}
