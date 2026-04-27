//! Axum extractor that turns `Authorization: Bearer <token>` into an `AuthIdentity`.

use async_trait::async_trait;
use axum::{
    extract::FromRequestParts,
    http::{request::Parts, StatusCode},
};

use crate::auth::{authenticate, AuthIdentity};
use crate::service::SandboxService;

fn extract_bearer(parts: &Parts) -> Option<&str> {
    parts
        .headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer ").or_else(|| s.strip_prefix("bearer ")))
}

/// Extractor for authenticated user identity. Rejects with 401 on invalid/missing token.
pub struct Auth(pub AuthIdentity);

#[async_trait]
impl FromRequestParts<SandboxService> for Auth {
    type Rejection = (StatusCode, String);

    async fn from_request_parts(
        parts: &mut Parts,
        service: &SandboxService,
    ) -> Result<Self, Self::Rejection> {
        let token = extract_bearer(parts)
            .ok_or((StatusCode::UNAUTHORIZED, "missing Bearer token".to_string()))?;

        authenticate(service.redis(), token)
            .await
            .map(Auth)
            .map_err(|e| (StatusCode::UNAUTHORIZED, e.to_string()))
    }
}

/// Like `Auth`, but no header → `None`. Invalid token still fails with 401.
pub struct OptionalAuth(pub Option<AuthIdentity>);

#[async_trait]
impl FromRequestParts<SandboxService> for OptionalAuth {
    type Rejection = (StatusCode, String);

    async fn from_request_parts(
        parts: &mut Parts,
        service: &SandboxService,
    ) -> Result<Self, Self::Rejection> {
        match extract_bearer(parts) {
            None => Ok(OptionalAuth(None)),
            Some(token) => authenticate(service.redis(), token)
                .await
                .map(|id| OptionalAuth(Some(id)))
                .map_err(|e| (StatusCode::UNAUTHORIZED, e.to_string())),
        }
    }
}
