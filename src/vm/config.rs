//! Configuration for the VM manager

use std::path::PathBuf;
use serde::{Deserialize, Serialize};

/// Root of all on-disk state: templates, overlays, snapshots, recovery CA.
/// `$DATA_DIR` (prod: `/data`), else `$HOME/sandbox-data` (dev), else
/// `/root/sandbox-data`. Single source of truth — every path default derives
/// from here so dev and prod layouts stay in lockstep.
pub fn data_dir() -> PathBuf {
    if let Ok(d) = std::env::var("DATA_DIR") {
        if !d.is_empty() {
            return PathBuf::from(d);
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    PathBuf::from(format!("{home}/sandbox-data"))
}

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
}

impl Default for ManagerConfig {
    fn default() -> Self {
        let data_dir = data_dir();

        Self {
            templates_dir: data_dir.join("templates"),
            overlays_dir: data_dir.join("overlays"),
            snapshots_dir: data_dir.join("snapshots"),
            bridge_name: "br-sandbox".into(),
            network_subnet: "10.0.0.0/16".into(),
            max_vms: 5000,
            default_size: "medium".into(),
        }
    }
}

impl ManagerConfig {
    /// Load from environment variables
    pub fn from_env() -> Self {
        let data_dir = data_dir();

        Self {
            templates_dir: std::env::var("TEMPLATES_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| data_dir.join("templates")),
            overlays_dir: std::env::var("OVERLAYS_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| data_dir.join("overlays")),
            snapshots_dir: std::env::var("SNAPSHOTS_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| data_dir.join("snapshots")),
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
            boot_args: "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/init".into(),
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
