use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;

use crate::api::auth_extractor::Auth;
use crate::service::errors::{rest_error, ErrorCode};
use crate::service::types::{CreateSandboxRequest, SandboxInfo, SandboxStats};
use crate::service::SandboxService;

/// Create a new sandbox (owned by the authenticated caller)
pub async fn create_sandbox(
    State(service): State<SandboxService>,
    Auth(identity): Auth,
    Json(req): Json<CreateSandboxRequest>,
) -> Result<Json<SandboxInfo>, (StatusCode, String)> {
    service
        .create_sandbox(&identity, req)
        .await
        .map(Json)
        .map_err(|e| rest_error(ErrorCode::Internal, e.to_string()))
}

/// Get sandbox details (caller must own it, or be admin)
pub async fn get_sandbox(
    State(service): State<SandboxService>,
    Auth(identity): Auth,
    Path(id): Path<String>,
) -> Result<Json<SandboxInfo>, (StatusCode, String)> {
    service
        .get_sandbox(&identity, &id)
        .await
        .map_err(|e| rest_error(ErrorCode::Internal, e.to_string()))?
        .map(Json)
        .ok_or(rest_error(ErrorCode::NotFound, "Sandbox not found"))
}

/// Delete a sandbox
pub async fn delete_sandbox(
    State(service): State<SandboxService>,
    Auth(identity): Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    service
        .delete_sandbox(&identity, &id)
        .await
        .map_err(|e| rest_error(ErrorCode::Forbidden, e.to_string()))?;

    Ok(StatusCode::NO_CONTENT)
}

/// Pause a sandbox
pub async fn pause_sandbox(
    State(service): State<SandboxService>,
    Auth(identity): Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    service
        .pause_sandbox(&identity, &id)
        .await
        .map_err(|e| rest_error(ErrorCode::BadRequest, e.to_string()))?;

    Ok(StatusCode::OK)
}

/// Resume a sandbox
pub async fn resume_sandbox(
    State(service): State<SandboxService>,
    Auth(identity): Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    service
        .resume_sandbox(&identity, &id)
        .await
        .map_err(|e| rest_error(ErrorCode::BadRequest, e.to_string()))?;

    Ok(StatusCode::OK)
}

/// Query params for listing sandboxes (admin-only `user_id` filter)
#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub user_id: Option<String>,
}

/// List sandboxes. Users see their own; admins can filter by user_id (or see all).
pub async fn list_sandboxes(
    State(service): State<SandboxService>,
    Auth(identity): Auth,
    Query(query): Query<ListQuery>,
) -> Result<Json<Vec<SandboxInfo>>, (StatusCode, String)> {
    service
        .list_sandboxes(&identity, query.user_id.as_deref())
        .await
        .map(Json)
        .map_err(|e| rest_error(ErrorCode::Internal, e.to_string()))
}

/// Get sandbox statistics
pub async fn get_stats(
    State(service): State<SandboxService>,
) -> Result<Json<SandboxStats>, (StatusCode, String)> {
    service
        .stats()
        .await
        .map(Json)
        .map_err(|e| rest_error(ErrorCode::Internal, e.to_string()))
}
