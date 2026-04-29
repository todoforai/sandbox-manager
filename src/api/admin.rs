//! Local admin routes — no auth required.
//!
//! These are mounted under `/admin/api/*` and intended to be reachable only
//! from the loopback interface (BIND_ADDR=127.0.0.1:9000 in our pm2 config,
//! and nginx never proxies `/admin/api/*` from the public side).
//!
//! All requests here run as a synthetic admin identity, so the same service
//! methods used by Bearer-authenticated admins handle them unchanged.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::Serialize;

use crate::auth::{AuthIdentity, Role};
use crate::service::errors::{rest_error, ErrorCode};
use crate::service::types::{SandboxInfo, SandboxStats};
use crate::service::SandboxService;
use crate::vm::sandbox::SandboxKind;

const LOG_TAIL_BYTES: u64 = 64 * 1024;

fn root_admin() -> AuthIdentity {
    AuthIdentity { user_id: "admin".into(), role: Role::Admin, is_anonymous: false }
}

pub async fn list_sandboxes(
    State(service): State<SandboxService>,
) -> Result<Json<Vec<SandboxInfo>>, (StatusCode, String)> {
    service
        .list_sandboxes(&root_admin(), None)
        .await
        .map(Json)
        .map_err(|e| rest_error(ErrorCode::Internal, e.to_string()))
}

pub async fn stats(
    State(service): State<SandboxService>,
) -> Result<Json<SandboxStats>, (StatusCode, String)> {
    service
        .stats()
        .await
        .map(Json)
        .map_err(|e| rest_error(ErrorCode::Internal, e.to_string()))
}

pub async fn delete_sandbox(
    State(service): State<SandboxService>,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    service
        .delete_sandbox(&root_admin(), &id)
        .await
        .map_err(|e| rest_error(ErrorCode::BadRequest, e.to_string()))?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn pause_sandbox(
    State(service): State<SandboxService>,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    service
        .pause_sandbox(&root_admin(), &id)
        .await
        .map_err(|e| rest_error(ErrorCode::BadRequest, e.to_string()))?;
    Ok(StatusCode::OK)
}

pub async fn resume_sandbox(
    State(service): State<SandboxService>,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    service
        .resume_sandbox(&root_admin(), &id)
        .await
        .map_err(|e| rest_error(ErrorCode::BadRequest, e.to_string()))?;
    Ok(StatusCode::OK)
}

#[derive(Serialize)]
pub struct SandboxLogs {
    kind: SandboxKind,
    state: String,
    error: Option<String>,
    console_log_path: Option<String>,
    console_log: Option<String>,
    fc_log_path: Option<String>,
    fc_log: Option<String>,
    note: Option<String>,
}

/// Read the last `LOG_TAIL_BYTES` of a file. Returns None if missing.
async fn tail_file(path: &std::path::Path) -> Option<String> {
    let mut f = tokio::fs::File::open(path).await.ok()?;
    use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};
    let len = f.metadata().await.ok()?.len();
    let start = len.saturating_sub(LOG_TAIL_BYTES);
    f.seek(SeekFrom::Start(start)).await.ok()?;
    let mut buf = Vec::with_capacity((len - start) as usize);
    f.read_to_end(&mut buf).await.ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

pub async fn sandbox_logs(
    State(service): State<SandboxService>,
    Path(id): Path<String>,
) -> Result<Json<SandboxLogs>, (StatusCode, String)> {
    let info = service
        .get_sandbox(&root_admin(), &id)
        .await
        .map_err(|e| rest_error(ErrorCode::Internal, e.to_string()))?
        .ok_or_else(|| rest_error(ErrorCode::NotFound, format!("sandbox {id} not found")))?;

    if info.kind == SandboxKind::Lite {
        return Ok(Json(SandboxLogs {
            kind: info.kind,
            state: info.state,
            error: info.error,
            console_log_path: None,
            console_log: None,
            fc_log_path: None,
            fc_log: None,
            note: Some("Lite sandboxes have no persistent logs (bwrap-based).".into()),
        }));
    }

    let runtime_dir = service.runtime_dir();
    let console_path = runtime_dir.join(format!("{id}.console.log"));
    let fc_path = runtime_dir.join(format!("{id}.fc.log"));
    let console_log = tail_file(&console_path).await;
    let fc_log = tail_file(&fc_path).await;

    Ok(Json(SandboxLogs {
        kind: info.kind,
        state: info.state,
        error: info.error,
        console_log_path: Some(console_path.to_string_lossy().into_owned()),
        console_log,
        fc_log_path: Some(fc_path.to_string_lossy().into_owned()),
        fc_log,
        note: None,
    }))
}
