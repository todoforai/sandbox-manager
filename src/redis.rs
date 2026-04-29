//! Redis client — Redis is the source of truth for:
//!   - Identity & billing (`apikey:*`, `resource:token:*`, `appuser:*`) — writer: backend
//!   - Sandbox inventory (`sandbox:*`) — writer: this service
//!
//! Inventory key schema:
//!   sandbox:<id>                STRING (JSON of Sandbox)
//!   sandbox:user:<userId>       SET    sandbox IDs owned by user (any state)
//!   sandbox:active              SET    sandbox IDs currently Running or Paused
//!   stats:sandbox:created       COUNTER  monotonic lifetime counter
//!
//! Stats/cleanup iterate `sandbox:active` (not all records); terminated/error
//! records still live in `sandbox:<id>` + `sandbox:user:<uid>` until deleted.
//!
//! Pub/sub:
//!   sandbox:events:<userId>     PUBLISH on every create / state-change / delete.
//!   Payload: full Sandbox JSON (same shape as `sandbox:<id>`), plus `deleted: true`
//!   on delete. Backend subscribes and re-emits to connected frontends.

use anyhow::{Context, Result};
use redis::{aio::MultiplexedConnection, AsyncCommands, Client, Script};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::vm::sandbox::{Sandbox, SandboxState};

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Parse ISO-8601 UTC (e.g. "2025-12-10T23:00:00.000Z") to unix ms.
/// Accepts `YYYY-MM-DDTHH:MM:SS[.fff]Z`. Returns None on any other shape.
fn parse_iso8601_ms(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 20 || b.last() != Some(&b'Z') || b[10] != b'T' { return None }
    let p = |a: usize, e: usize| std::str::from_utf8(&b[a..e]).ok()?.parse::<i64>().ok();
    let (y, mo, d) = (p(0, 4)?, p(5, 7)?, p(8, 10)?);
    let (h, mi, se) = (p(11, 13)?, p(14, 16)?, p(17, 19)?);
    let ms = if b[19] == b'.' { p(20, 23).unwrap_or(0) } else { 0 };
    // Howard Hinnant's date algorithm — works for any year ≥ -32767.
    let y = y - if mo <= 2 { 1 } else { 0 };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;                        // [0, 399]
    let m_shift = if mo > 2 { mo - 3 } else { mo + 9 };
    let doy = (153 * m_shift + 2) / 5 + d - 1;      // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    let total_ms = days * 86_400_000 + h * 3_600_000 + mi * 60_000 + se * 1000 + ms;
    if total_ms < 0 { None } else { Some(total_ms as u64) }
}

#[cfg(test)]
mod date_tests {
    use super::parse_iso8601_ms;
    #[test] fn iso_basic() {
        assert_eq!(parse_iso8601_ms("1970-01-01T00:00:00.000Z"), Some(0));
        assert_eq!(parse_iso8601_ms("2025-12-10T23:00:00.000Z"), Some(1_765_407_600_000));
        assert_eq!(parse_iso8601_ms("2024-02-29T12:00:00.000Z"), Some(1_709_208_000_000));
        assert_eq!(parse_iso8601_ms("2025-12-10T23:00:00Z"),     Some(1_765_407_600_000));
    }
    #[test] fn iso_invalid() {
        assert_eq!(parse_iso8601_ms("garbage"), None);
        assert_eq!(parse_iso8601_ms("2025-12-10X23:00:00.000Z"), None);
        assert_eq!(parse_iso8601_ms(""), None);
    }
}

fn events_channel(user_id: &str) -> String {
    format!("sandbox:events:{user_id}")
}

#[derive(Clone)]
pub struct RedisClient {
    inner: Arc<RwLock<Option<MultiplexedConnection>>>,
}

impl RedisClient {
    pub async fn connect(url: &str) -> Result<Self> {
        let client = Client::open(url).context("Invalid Redis URL")?;
        let conn = client
            .get_multiplexed_async_connection()
            .await
            .context("Failed to connect to Redis")?;
        tracing::info!("Redis connected: {}", url);
        Ok(Self {
            inner: Arc::new(RwLock::new(Some(conn))),
        })
    }

    async fn conn(&self) -> Result<MultiplexedConnection> {
        let guard = self.inner.read().await;
        guard.clone().context("Redis not connected")
    }

    // ── Identity ──────────────────────────────────────────────────────────────

    /// Resolve token → (userId, role). Sources, in order:
    ///   1. `resource:token:<token>` STRING → userId  (short-lived, role=user)
    ///   2. `apikey:<token>` HASH `{userId, role?}`   (long-lived; only source that may be admin)
    ///   3. Better Auth session: `session:idx:token:<token>` SET → sessionId,
    ///      `session:<id>` HASH `{userId, expiresAt}`. Role is `guest` if the
    ///      `user:<userId>.isAnonymous` flag is set, else `user`.
    /// Resource tokens never carry admin role; only apikey:<token> can.
    pub async fn resolve_identity(&self, token: &str) -> Result<Option<(String, String)>> {
        let mut conn = self.conn().await?;

        if let Some(user_id) = conn.get::<_, Option<String>>(format!("resource:token:{token}")).await? {
            return Ok(Some((user_id, "user".into())));
        }

        let (user_id, role): (Option<String>, Option<String>) =
            conn.hget(format!("apikey:{token}"), &["userId", "role"][..]).await?;
        if let Some(uid) = user_id {
            return Ok(Some((uid, role.unwrap_or_else(|| "user".into()))));
        }

        // Better Auth bearer/session token. Schema written by backend's
        // SessionRepository — see backend/src/redis/repositories.ts:637.
        let session_ids: Vec<String> = conn.smembers(format!("session:idx:token:{token}")).await?;
        let Some(sid) = session_ids.into_iter().next() else { return Ok(None) };
        let (uid, expires_at): (Option<String>, Option<String>) =
            conn.hget(format!("session:{sid}"), &["userId", "expiresAt"][..]).await?;
        let Some(uid) = uid else { return Ok(None) };
        if let Some(exp) = expires_at {
            // ISO-8601 UTC, e.g. "2025-12-10T23:00:00.000Z". Reject expired sessions.
            if let Some(exp_ms) = parse_iso8601_ms(&exp) {
                if exp_ms < now_ms() { return Ok(None) }
            }
        }
        let is_anon: Option<String> = conn.hget(format!("user:{uid}"), "isAnonymous").await?;
        let role = if is_anon.as_deref() == Some("1") { "guest" } else { "user" };
        Ok(Some((uid, role.into())))
    }

    // ── Billing (unused until metering wired up) ──────────────────────────────

    /// Atomically deduct `amount` from user balance.
    /// Drains subscriptionBalance first, overflows to manualBalance.
    /// Returns new total balance.
    #[allow(dead_code)]
    pub async fn deduct_balance(&self, user_id: &str, amount: f64) -> Result<f64> {
        let mut conn = self.conn().await?;
        let script = Script::new(
            r#"
            local key = KEYS[1]
            local amount = tonumber(ARGV[1])
            local subBal = tonumber(redis.call('HGET', key, 'subscriptionBalance') or '0')
            if subBal >= amount then
                redis.call('HINCRBYFLOAT', key, 'subscriptionBalance', -amount)
            else
                local overflow = amount - subBal
                if subBal > 0 then redis.call('HSET', key, 'subscriptionBalance', '0') end
                redis.call('HINCRBYFLOAT', key, 'manualBalance', -overflow)
            end
            local newBalance = redis.call('HINCRBYFLOAT', key, 'balance', -amount)
            redis.call('HINCRBYFLOAT', key, 'subscriptionUsageThisMonth', amount)
            return newBalance
            "#,
        );
        let new_balance: String = script
            .key(format!("appuser:{user_id}"))
            .arg(amount.to_string())
            .invoke_async(&mut conn)
            .await
            .context("deduct_balance script failed")?;
        Ok(new_balance.parse().unwrap_or(0.0))
    }

    // ── Sandbox inventory ─────────────────────────────────────────────────────

    /// Insert/replace a sandbox record, keep set memberships consistent, and
    /// publish the current state to `sandbox:events:<userId>` in the same
    /// MULTI/EXEC pipeline so subscribers never see a write without its event.
    /// Called on initial creation and after state transitions reached via
    /// direct `sandbox_put` (e.g. boot finish).
    pub async fn sandbox_put(&self, s: &Sandbox) -> Result<()> {
        let mut conn = self.conn().await?;
        let json = serde_json::to_string(s).context("serialize sandbox")?;

        let mut pipe = redis::pipe();
        pipe.atomic()
            .set(format!("sandbox:{}", s.id), &json).ignore()
            .sadd(format!("sandbox:user:{}", s.user_id), &s.id).ignore();
        if s.is_active() {
            pipe.sadd("sandbox:active", &s.id).ignore();
        } else {
            pipe.srem("sandbox:active", &s.id).ignore();
        }
        pipe.publish(events_channel(&s.user_id), &json).ignore();

        pipe.query_async::<()>(&mut conn)
            .await
            .context("sandbox_put pipeline failed")?;
        Ok(())
    }

    /// Bump the lifetime-created counter. Called once on successful boot.
    pub async fn sandbox_inc_created(&self) -> Result<()> {
        let mut conn = self.conn().await?;
        let _: i64 = conn.incr("stats:sandbox:created", 1).await?;
        Ok(())
    }

    /// Read the lifetime-created counter.
    pub async fn sandbox_total_created(&self) -> Result<u64> {
        let mut conn = self.conn().await?;
        let v: Option<String> = conn.get("stats:sandbox:created").await?;
        Ok(v.and_then(|s| s.parse().ok()).unwrap_or(0))
    }

    pub async fn sandbox_get(&self, id: &str) -> Result<Option<Sandbox>> {
        let mut conn = self.conn().await?;
        let json: Option<String> = conn.get(format!("sandbox:{id}")).await?;
        match json {
            Some(j) => Ok(Some(serde_json::from_str(&j).context("deserialize sandbox")?)),
            None => Ok(None),
        }
    }

    /// Read-modify-write on the sandbox record: updates `state`, `last_activity`
    /// and optionally `error`, keeps `sandbox:active` in sync, and publishes the
    /// new state on `sandbox:events:<userId>`.
    ///
    /// The read and write are separate round-trips; in this service only one
    /// logical op is ever in flight per sandbox (create/pause/resume/delete
    /// are user-driven and serialized per id), so the lost-update race is
    /// unreachable in practice. No-op if the record was deleted concurrently.
    pub async fn sandbox_set_state(&self, id: &str, state: SandboxState, error: Option<&str>) -> Result<()> {
        let mut conn = self.conn().await?;

        let raw: Option<String> = conn.get(format!("sandbox:{id}")).await?;
        let Some(raw) = raw else { return Ok(()); };
        let mut obj: Sandbox = serde_json::from_str(&raw).context("deserialize sandbox")?;

        obj.state = state;
        obj.last_activity = now_ms();
        // Update error field: explicit message wins; otherwise any non-error
        // transition (Running/Paused/Terminated/etc.) clears a stale error.
        // Only `SandboxState::Error` with `None` preserves the existing value.
        obj.error = match (state, error) {
            (_, Some(e)) => Some(e.to_string()),
            (SandboxState::Error, None) => obj.error,
            _ => None,
        };

        let new_json = serde_json::to_string(&obj).context("serialize sandbox")?;
        let is_active = matches!(state, SandboxState::Running | SandboxState::Paused);

        let mut pipe = redis::pipe();
        pipe.atomic()
            .set(format!("sandbox:{id}"), &new_json).ignore();
        if is_active {
            pipe.sadd("sandbox:active", id).ignore();
        } else {
            pipe.srem("sandbox:active", id).ignore();
        }
        pipe.publish(events_channel(&obj.user_id), &new_json).ignore();

        pipe.query_async::<()>(&mut conn)
            .await
            .context("sandbox_set_state pipeline failed")?;
        Ok(())
    }

    /// Remove the sandbox record and all set memberships, then publish a
    /// `{id, user_id, deleted: true}` event so subscribers can drop the row.
    /// Read-then-pipelined-delete; see `sandbox_set_state` for the race note.
    pub async fn sandbox_delete(&self, id: &str) -> Result<()> {
        let mut conn = self.conn().await?;

        let raw: Option<String> = conn.get(format!("sandbox:{id}")).await?;
        let Some(raw) = raw else { return Ok(()); };
        let obj: Sandbox = serde_json::from_str(&raw).context("deserialize sandbox")?;

        let event = serde_json::json!({
            "id": id,
            "user_id": obj.user_id,
            "deleted": true,
        })
        .to_string();

        redis::pipe()
            .atomic()
            .del(format!("sandbox:{id}")).ignore()
            .srem("sandbox:active", id).ignore()
            .srem(format!("sandbox:user:{}", obj.user_id), id).ignore()
            .publish(events_channel(&obj.user_id), &event).ignore()
            .query_async::<()>(&mut conn)
            .await
            .context("sandbox_delete pipeline failed")?;
        Ok(())
    }

    async fn hydrate(&self, ids: Vec<String>) -> Result<Vec<Sandbox>> {
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            match self.sandbox_get(&id).await {
                Ok(Some(s)) => out.push(s),
                Ok(None) => {}
                Err(e) => tracing::warn!("hydrate: skipping undecodable sandbox {id}: {e}"),
            }
        }
        Ok(out)
    }

    /// List a user's sandboxes (any state) if `user_id` is set, otherwise every
    /// sandbox across all users (any state) — used by the admin view.
    /// Scans `sandbox:user:*` to include terminated/error records, not just `sandbox:active`.
    pub async fn sandbox_list(&self, user_id: Option<&str>) -> Result<Vec<Sandbox>> {
        let mut conn = self.conn().await?;
        let ids: Vec<String> = match user_id {
            Some(uid) => conn.smembers(format!("sandbox:user:{uid}")).await?,
            None => {
                let mut all = std::collections::HashSet::<String>::new();
                let mut iter = conn.scan_match::<_, String>("sandbox:user:*").await?;
                let mut user_keys = Vec::new();
                while let Some(k) = iter.next_item().await { user_keys.push(k); }
                drop(iter);
                for key in user_keys {
                    let members: Vec<String> = conn.smembers(&key).await?;
                    all.extend(members);
                }
                all.into_iter().collect()
            }
        };
        self.hydrate(ids).await
    }

    /// Count active sandboxes for a user (for quota enforcement).
    /// O(user_active_sandboxes) — cheap because active is the bounded set.
    pub async fn sandbox_user_active_count(&self, user_id: &str) -> Result<usize> {
        let mut conn = self.conn().await?;
        let user_ids: std::collections::HashSet<String> =
            conn.smembers(format!("sandbox:user:{user_id}")).await?;
        let active_ids: std::collections::HashSet<String> =
            conn.smembers("sandbox:active").await?;
        Ok(user_ids.intersection(&active_ids).count())
    }

    /// All sandbox IDs currently in `sandbox:active`. Used for startup reconciliation.
    pub async fn sandbox_active_ids(&self) -> Result<Vec<String>> {
        let mut conn = self.conn().await?;
        let ids: Vec<String> = conn.smembers("sandbox:active").await?;
        Ok(ids)
    }
}

/// Build RedisClient from DRAGONFLY_URL env var (shared with backend).
pub async fn connect_from_env() -> Result<RedisClient> {
    let url = std::env::var("DRAGONFLY_URL").context("DRAGONFLY_URL env var required")?;
    RedisClient::connect(&url).await
}
