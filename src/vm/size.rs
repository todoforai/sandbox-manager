//! VM size tiers - small, medium, large, custom
//! 
//! Each tier defines resource limits for the VM.
//! CoW means base memory is shared - only dirty pages count against the limit.

use serde::{Deserialize, Serialize};

/// VM size tier
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum VmSize {
    /// 128MB RAM, 1 vCPU — simple scripts, quick tasks (~$0.0025/min)
    Small,
    
    /// 256MB RAM, 1 vCPU — most agent tasks, npm install, git (~$0.005/min)
    #[default]
    Medium,
    
    /// 512MB RAM, 2 vCPU — builds, heavy computation, multiple processes (~$0.01/min)
    Large,
    
    /// 1024MB RAM, 4 vCPU — large builds, ML inference, memory-intensive tasks (~$0.02/min)
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
    
    /// Cost per minute in USD (VM tier price; Lite sandboxes are billed at
    /// $0 — see `SandboxInfo::from(Sandbox)` in `service/types.rs`).
    ///
    /// Named tiers price purely on memory at $0.0025/128MB/min; vCPU count
    /// happens to scale with memory in our tiers so it doesn't need its own
    /// term. Custom sizes use the same per-MB rate for continuity.
    pub fn cost_per_minute(&self) -> f64 {
        match self {
            VmSize::Small => 0.0025,
            VmSize::Medium => 0.005,
            VmSize::Large => 0.01,
            VmSize::XLarge => 0.02,
            VmSize::Custom { memory_mb, .. } => {
                *memory_mb as f64 * (0.0025 / 128.0)
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
        // Exact rates — guard against accidental pricing drift.
        assert_eq!(VmSize::Small.cost_per_minute(),  0.0025);
        assert_eq!(VmSize::Medium.cost_per_minute(), 0.005);
        assert_eq!(VmSize::Large.cost_per_minute(),  0.01);
        assert_eq!(VmSize::XLarge.cost_per_minute(), 0.02);

        // Custom matches named tiers at the same memory.
        let custom_small = VmSize::Custom { memory_mb: 128, vcpu_count: 1 };
        assert_eq!(custom_small.cost_per_minute(), VmSize::Small.cost_per_minute());
        let custom_xl = VmSize::Custom { memory_mb: 1024, vcpu_count: 4 };
        assert_eq!(custom_xl.cost_per_minute(), VmSize::XLarge.cost_per_minute());
    }
}
