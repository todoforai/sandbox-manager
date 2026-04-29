//! Auth — resolve a Bearer token to an AuthIdentity via Redis.
//!
//! Sources are documented on `RedisClient::resolve_identity`.

use anyhow::Result;

use crate::redis::RedisClient;

/// Who is making the request.
#[derive(Debug, Clone)]
pub struct AuthIdentity {
    pub user_id: String,
    pub role: Role,
    /// Better Auth `isAnonymous=1`. Anonymous users are restricted to lite templates.
    pub is_anonymous: bool,
}

impl AuthIdentity {
    pub fn is_admin(&self) -> bool { matches!(self.role, Role::Admin) }
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
    let (user_id, role, is_anonymous) = redis
        .resolve_identity(token)
        .await?
        .ok_or_else(|| anyhow::anyhow!("invalid token"))?;

    Ok(AuthIdentity {
        user_id,
        role: Role::from_str(&role),
        is_anonymous,
    })
}


