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

use std::process::Command;

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

/// One-shot recovery shell script. Generates an ephemeral keypair locally
/// (via `ssh-keygen -t ed25519`), mints a sandbox-scoped SSH cert, and bakes
/// everything into a self-contained bash script. The operator copies it from
/// the admin UI and runs it on the manager host — no Bearer token needed.
///
/// Loopback admin only (mounted under `/admin/api/*`). The returned script
/// contains a short-lived private key + cert (default 600s); treat the
/// response like any other operator credential.
#[derive(Serialize)]
pub struct RecoveryScriptResponse {
    pub script: String,
    pub ttl_secs: u64,
    pub principal: String,
}

pub async fn recovery_script(
    State(service): State<SandboxService>,
    Path(id): Path<String>,
) -> Result<Json<RecoveryScriptResponse>, (StatusCode, String)> {
    // Generate ephemeral ed25519 keypair using the system's ssh-keygen so the
    // resulting `id` is in OpenSSH format that the host's ssh client expects.
    // tempfile crate isn't a dep — use a process-unique path under /tmp.
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let key_path = std::env::temp_dir().join(format!("sm-recovery-{}-{nonce}", std::process::id()));
    let _ = std::fs::remove_file(&key_path);
    let _ = std::fs::remove_file(key_path.with_extension("pub"));

    let st = Command::new("ssh-keygen")
        .args(["-t", "ed25519", "-N", "", "-q", "-C", "recovery@admin", "-f"])
        .arg(&key_path)
        .status()
        .map_err(|e| rest_error(ErrorCode::Internal, format!("ssh-keygen: {e}")))?;
    if !st.success() {
        return Err(rest_error(ErrorCode::Internal, "ssh-keygen failed".to_string()));
    }
    // Read both halves and immediately remove from disk — the script will
    // recreate them in the operator's $TMPDIR with mode 0600.
    let priv_pem = std::fs::read_to_string(&key_path)
        .map_err(|e| rest_error(ErrorCode::Internal, format!("read priv: {e}")))?;
    let pub_line = std::fs::read_to_string(key_path.with_extension("pub"))
        .map_err(|e| rest_error(ErrorCode::Internal, format!("read pub: {e}")))?;
    let _ = std::fs::remove_file(&key_path);
    let _ = std::fs::remove_file(key_path.with_extension("pub"));

    let resp = service
        .issue_recovery_cert(&root_admin(), &id, &pub_line, None)
        .await
        .map_err(|e| rest_error(ErrorCode::BadRequest, e.to_string()))?;

    // Heredoc-quoted with 'EOF' so $vars inside the keys aren't expanded.
    let script = format!(
        r#"#!/usr/bin/env bash
# Recovery SSH for sandbox {id}
# Cert principal: {principal}
# Cert TTL: {ttl}s — re-generate from the admin panel after expiry.
set -euo pipefail
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077
cat > "$WORK/id" <<'KEY_EOF'
{priv}KEY_EOF
cat > "$WORK/id-cert.pub" <<'CERT_EOF'
{cert}
CERT_EOF
chmod 600 "$WORK/id" "$WORK/id-cert.pub"
exec ssh \
    -i "$WORK/id" \
    -o "CertificateFile=$WORK/id-cert.pub" \
    -o "ProxyCommand=fc-vsock-proxy {uds} {port}" \
    -o "UserKnownHostsFile=/dev/null" \
    -o "StrictHostKeyChecking=accept-new" \
    -o "LogLevel=ERROR" \
    recovery@sandbox "$@"
"#,
        id = id,
        principal = resp.principal,
        ttl = resp.ttl_secs,
        priv = priv_pem,           // already ends with newline
        cert = resp.cert.trim_end(),
        uds = resp.vsock_uds_path,
        port = resp.vsock_port,
    );

    Ok(Json(RecoveryScriptResponse {
        script,
        ttl_secs: resp.ttl_secs,
        principal: resp.principal,
    }))
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
