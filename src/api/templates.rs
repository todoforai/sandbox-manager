use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;

use crate::service::errors::{rest_error, ErrorCode};
use crate::service::SandboxService;
use crate::vm::config::TemplateConfig;

/// List available templates
pub async fn list_templates(
    State(service): State<SandboxService>,
) -> Json<Vec<String>> {
    Json(service.list_templates())
}

/// Request to create a template
#[derive(Debug, Deserialize)]
pub struct CreateTemplateRequest {
    /// Path to kernel image
    pub kernel_path: String,
    /// Path to rootfs image
    pub rootfs_path: String,
    /// Boot arguments
    pub boot_args: Option<String>,
    /// Description
    pub description: Option<String>,
    /// Pre-installed packages
    pub packages: Option<Vec<String>>,
}

/// Create a new template
pub async fn create_template(
    State(service): State<SandboxService>,
    Path(name): Path<String>,
    Json(req): Json<CreateTemplateRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let config = TemplateConfig {
        name: name.clone(),
        kernel_path: req.kernel_path.into(),
        rootfs_path: req.rootfs_path.into(),
        boot_args: req.boot_args.unwrap_or_else(|| {
            "console=ttyS0 reboot=k panic=1 pci=off init=/sbin/init".into()
        }),
        description: req.description.unwrap_or_default(),
        packages: req.packages.unwrap_or_default(),
        ..Default::default()
    };

    service
        .load_template(&name, &config)
        .await
        .map_err(|e| rest_error(ErrorCode::Internal, e.to_string()))?;

    Ok(StatusCode::CREATED)
}
