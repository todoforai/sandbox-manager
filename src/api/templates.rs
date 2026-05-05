use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};

use crate::service::errors::{rest_error, ErrorCode};
use crate::service::types::CreateTemplateRequest;
use crate::service::SandboxService;

/// List available templates
pub async fn list_templates(
    State(service): State<SandboxService>,
) -> Json<Vec<String>> {
    Json(service.list_templates())
}

/// Create a new template
pub async fn create_template(
    State(service): State<SandboxService>,
    Path(name): Path<String>,
    Json(req): Json<CreateTemplateRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let config = req.into_config(name.clone());
    service
        .load_template(&name, &config)
        .await
        .map_err(|e| rest_error(ErrorCode::Internal, e.to_string()))?;
    Ok(StatusCode::CREATED)
}
