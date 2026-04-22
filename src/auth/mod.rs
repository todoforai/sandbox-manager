//! Auth — resolve a Bearer token to an AuthIdentity via Redis.
//!
//! Sources (in order):
//!   1. `resource:token:<token>` → userId  (short-lived, role=User)
//!   2. `apikey:<token>` HASH { userId, role? } (long-lived, role default=User)

use anyhow::{bail, Result};

use crate::redis::RedisClient;

/// Who is making the request.
#[derive(Debug, Clone)]
pub struct AuthIdentity {
    pub user_id: String,
    pub role: Role,
}

impl AuthIdentity {
    pub fn is_admin(&self) -> bool {
        matches!(self.role, Role::Admin)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Admin,
}

impl Role {
    fn from_str(s: &str) -> Self {
        match s {
            "admin" => Role::Admin,
            _ => Role::User,
        }
    }
}

/// Resolve a bearer token to an identity. Returns error if the token is invalid.
pub async fn authenticate(redis: &RedisClient, token: &str) -> Result<AuthIdentity> {
    let (user_id, role) = redis
        .resolve_identity(token)
        .await?
        .ok_or_else(|| anyhow::anyhow!("invalid token"))?;

    Ok(AuthIdentity {
        user_id,
        role: Role::from_str(&role),
    })
}

/// Require admin role.
pub fn require_admin(identity: &AuthIdentity) -> Result<()> {
    if !identity.is_admin() {
        bail!("admin role required");
    }
    Ok(())
}
