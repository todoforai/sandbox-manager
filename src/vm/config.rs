//! Configuration for the VM manager

use std::path::PathBuf;
use serde::{Deserialize, Serialize};

/// Manager configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagerConfig {
    /// Path to templates directory
    pub templates_dir: PathBuf,
    
    /// Path to VM overlays directory  
    pub overlays_dir: PathBuf,
    
    /// Path to snapshots directory
    pub snapshots_dir: PathBuf,
    
    /// Network bridge name
    pub bridge_name: String,
    
    /// Network subnet (CIDR)
    pub network_subnet: String,
    
    /// Maximum concurrent VMs
    pub max_vms: u32,
    
    /// Default VM size
    pub default_size: String,
    
    /// Enable KVM (false for testing without KVM)
    pub enable_kvm: bool,
}

impl Default for ManagerConfig {
    fn default() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        let data_dir = std::env::var("DATA_DIR")
            .unwrap_or_else(|_| format!("{}/sandbox-data", home));
        
        Self {
            templates_dir: PathBuf::from(format!("{}/templates", data_dir)),
            overlays_dir: PathBuf::from(format!("{}/overlays", data_dir)),
            snapshots_dir: PathBuf::from(format!("{}/snapshots", data_dir)),
            bridge_name: "br-sandbox".into(),
            network_subnet: "10.0.0.0/16".into(),
            max_vms: 5000,
            default_size: "medium".into(),
            enable_kvm: true,
        }
    }
}

impl ManagerConfig {
    /// Load from environment variables
    pub fn from_env() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        let default_data_dir = format!("{}/sandbox-data", home);
        
        let data_dir = std::env::var("DATA_DIR").unwrap_or(default_data_dir);
        
        Self {
            templates_dir: std::env::var("TEMPLATES_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from(format!("{}/templates", data_dir))),
            overlays_dir: std::env::var("OVERLAYS_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from(format!("{}/overlays", data_dir))),
            snapshots_dir: std::env::var("SNAPSHOTS_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from(format!("{}/snapshots", data_dir))),
            bridge_name: std::env::var("BRIDGE_NAME")
                .unwrap_or_else(|_| "br-sandbox".into()),
            network_subnet: std::env::var("NETWORK_SUBNET")
                .unwrap_or_else(|_| "10.0.0.0/16".into()),
            max_vms: std::env::var("MAX_VMS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(5000),
            default_size: std::env::var("DEFAULT_VM_SIZE")
                .unwrap_or_else(|_| "medium".into()),
            enable_kvm: std::env::var("ENABLE_KVM")
                .map(|s| s != "false" && s != "0")
                .unwrap_or(true),
        }
    }
}

/// Template configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemplateConfig {
    /// Template name
    pub name: String,
    
    /// Path to kernel image
    pub kernel_path: PathBuf,
    
    /// Path to rootfs image
    pub rootfs_path: PathBuf,
    
    /// Path to memory snapshot
    pub memory_path: PathBuf,
    
    /// Path to vmstate snapshot
    pub vmstate_path: PathBuf,
    
    /// Boot arguments
    pub boot_args: String,
    
    /// Pre-installed packages
    pub packages: Vec<String>,
    
    /// Description
    pub description: String,
}

impl Default for TemplateConfig {
    fn default() -> Self {
        Self {
            name: "ubuntu-base".into(),
            kernel_path: PathBuf::from("vmlinux"),
            rootfs_path: PathBuf::from("rootfs.ext4"),
            memory_path: PathBuf::from("memory.snap"),
            vmstate_path: PathBuf::from("vmstate.snap"),
            boot_args: "console=ttyS0 reboot=k panic=1 pci=off init=/init".into(),
            packages: vec![
                "bash".into(), "curl".into(), "wget".into(), "git".into(),
                "jq".into(), "zip".into(), "unzip".into(), "rsync".into(),
                "build-essential".into(),
                "sqlite3".into(), "openssl".into(),
                "nodejs".into(), "npm".into(),
                "python3".into(), "python3-pip".into(),
            ],
            description: "Ubuntu Base with Node.js, Python3, build tools, git, jq, sqlite".into(),
        }
    }
}
