use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::api::auth_extractor::Auth;
use crate::service::errors::{rest_error, ErrorCode};
use crate::service::types::{CreateSandboxRequest, SandboxInfo, SandboxStats};
use crate::service::SandboxService;
use crate::vm::lite::ExecOutput;

/// Create a new sandbox.
///
/// Auth required for VM sandboxes. Anonymous callers may create a `lite`
/// sandbox on the allow-listed templates (e.g. `cli-lite`).
pub async fn create_sandbox(
    State(service): State<SandboxService>,
    Auth(identity): Auth,
    Json(req): Json<CreateSandboxRequest>,
) -> Result<Json<SandboxInfo>, (StatusCode, String)> {
    service
        .create_sandbox(&identity, req)
        .await
        .map(Json)
        .map_err(|e| rest_error(ErrorCode::BadRequest, e.to_string()))
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

/// Set the virtio-balloon target (MiB). Guest gives that much RAM back to the host.
#[derive(Debug, Deserialize)]
pub struct BalloonRequest {
    pub target_mib: u32,
}

pub async fn balloon_sandbox(
    State(service): State<SandboxService>,
    Auth(identity): Auth,
    Path(id): Path<String>,
    Json(req): Json<BalloonRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    service
        .balloon_sandbox(&identity, &id, req.target_mib)
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

/// Run a CLI command inside a lite sandbox.
#[derive(Debug, Deserialize)]
pub struct ExecRequest {
    /// argv[0] is the binary name; must be in the template's allow-list.
    pub argv: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct ExecResponse {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl From<ExecOutput> for ExecResponse {
    fn from(o: ExecOutput) -> Self {
        Self { exit_code: o.exit_code, stdout: o.stdout, stderr: o.stderr }
    }
}

pub async fn exec_sandbox(
    State(service): State<SandboxService>,
    Auth(identity): Auth,
    Path(id): Path<String>,
    Json(req): Json<ExecRequest>,
) -> Result<Json<ExecResponse>, (StatusCode, String)> {
    service
        .exec_sandbox(&identity, &id, &req.argv)
        .await
        .map(|o| Json(o.into()))
        .map_err(|e| rest_error(ErrorCode::BadRequest, e.to_string()))
}
