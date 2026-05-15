//! Axum extractor that turns a credential into an `AuthIdentity`.
//!
//! Supported sources, in order:
//!   1. `Authorization: Bearer <token>` — CLI/API clients and the Tauri app.
//!      No Origin check (these clients don't expose ambient credentials to
//!      the browser).
//!   2. Better Auth session cookie (`better-auth.session_token` or its
//!      `__Secure-` variant in production). The cookie value is
//!      `encodeURIComponent("<token>.<base64-hmac>")` — we percent-decode it,
//!      strip the signature, and let Redis validate the raw token via
//!      `session:idx:token:*`. Cross-subdomain cookies are configured on the
//!      backend (`crossSubDomainCookies: { domain: "todofor.ai" }`) so the
//!      cookie is sent to `sandbox.todofor.ai` automatically.
//!
//!      Cookie auth is ambient, so for state-changing methods we enforce
//!      that the `Origin` header is in an allow-list — same idea as
//!      `SameSite=Strict` but checked server-side so SameSite quirks
//!      (browsers without it, redirects from non-browsers) don't bypass it.

use async_trait::async_trait;
use axum::{
    extract::FromRequestParts,
    http::{request::Parts, Method, StatusCode},
};
use percent_encoding::percent_decode_str;

use crate::auth::{authenticate, AuthIdentity};
use crate::service::SandboxService;

const SESSION_COOKIE_NAMES: &[&str] = &[
    "better-auth.session_token",
    "__Secure-better-auth.session_token",
];

/// Origins allowed to perform cookie-authenticated mutations. Local dev hosts
/// are included so the dev server (web/dev-server.js) works without a manual
/// CORS toggle; prod hosts are the only ones the browser will actually send
/// the shared `.todofor.ai` cookie to.
const ALLOWED_COOKIE_ORIGINS: &[&str] = &[
    "https://sandbox.todofor.ai",
    "https://vm.todofor.ai",
    "http://localhost:8190",
    "http://127.0.0.1:8190",
    "http://localhost:3000",
];

/// Extractor for authenticated user identity. Rejects with 401 on invalid/missing
/// token. For cookie-authenticated mutating requests, also rejects with 403 if the
/// `Origin` header is missing or not in `ALLOWED_COOKIE_ORIGINS` (CSRF guard).
pub struct Auth(pub AuthIdentity);

#[async_trait]
impl FromRequestParts<SandboxService> for Auth {
    type Rejection = (StatusCode, String);

    async fn from_request_parts(
        parts: &mut Parts,
        service: &SandboxService,
    ) -> Result<Self, Self::Rejection> {
        let bearer = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.strip_prefix("Bearer ").or_else(|| s.strip_prefix("bearer ")))
            .map(str::to_string);

        let (token, used_cookie) = match bearer {
            Some(t) => (t, false),
            None => match session_token_from_cookies(parts) {
                Some(t) => (t, true),
                None => return Err((
                    StatusCode::UNAUTHORIZED,
                    "missing Bearer token or session cookie".to_string(),
                )),
            },
        };

        if used_cookie && !is_safe_method(&parts.method) && !origin_allowed(parts) {
            return Err((
                StatusCode::FORBIDDEN,
                "cookie-authenticated mutations require an allowed Origin".to_string(),
            ));
        }

        authenticate(service.redis(), &token)
            .await
            .map(Auth)
            .map_err(|e| (StatusCode::UNAUTHORIZED, e.to_string()))
    }
}

fn is_safe_method(m: &Method) -> bool {
    matches!(*m, Method::GET | Method::HEAD | Method::OPTIONS)
}

fn origin_allowed(parts: &Parts) -> bool {
    parts
        .headers
        .get(axum::http::header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .map(|o| ALLOWED_COOKIE_ORIGINS.contains(&o))
        .unwrap_or(false)
}

/// Pull the Better Auth session token out of the `Cookie` header. The cookie
/// value is `encodeURIComponent("<token>.<hmac>")` — we decode it, strip the
/// trailing signature, and return the raw token. Redis is the source of truth.
fn session_token_from_cookies(parts: &Parts) -> Option<String> {
    let header = parts.headers.get(axum::http::header::COOKIE)?.to_str().ok()?;
    for pair in header.split(';') {
        let Some((name, value)) = pair.split_once('=') else { continue; };
        if !SESSION_COOKIE_NAMES.contains(&name.trim()) { continue; }
        let decoded = percent_decode_str(value.trim()).decode_utf8().ok()?;
        // Strip the trailing ".<signature>". Use rsplit so a token containing
        // a `.` (defence in depth — Better Auth's current tokens don't, but
        // we shouldn't rely on that) still resolves correctly.
        let token = decoded.rsplit_once('.').map(|(t, _)| t).unwrap_or(&decoded);
        if !token.is_empty() { return Some(token.to_string()); }
    }
    None
}
