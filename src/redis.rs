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

use crate::vm::sandbox::{Sandbox, SandboxState};

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Parse RFC 3339 / ISO-8601 to unix ms. Returns None on bad input or
/// pre-epoch timestamps (we only ever compare against `now`).
fn parse_iso8601_ms(s: &str) -> Option<u64> {
    chrono::DateTime::parse_from_rfc3339(s).ok()?.timestamp_millis().try_into().ok()
}

fn events_channel(user_id: &str) -> String {
    format!("sandbox:events:{user_id}")
}

/// Cloning is cheap: `MultiplexedConnection` is itself a handle to a shared
/// connection, multiplexing requests over the same socket.
#[derive(Clone)]
pub struct RedisClient {
    conn: MultiplexedConnection,
}

impl RedisClient {
    pub async fn connect(url: &str) -> Result<Self> {
        let client = Client::open(url).context("Invalid Redis URL")?;
        let conn = client
            .get_multiplexed_async_connection()
            .await
            .context("Failed to connect to Redis")?;
        tracing::info!("Redis connected: {}", url);
        Ok(Self { conn })
    }

    fn conn(&self) -> MultiplexedConnection {
        self.conn.clone()
    }

    // ── Identity ──────────────────────────────────────────────────────────────

    /// Resolve token → (userId, role, isAnonymous). Sources, in order:
    ///   1. `resource:token:<token>` STRING → userId  (short-lived, role=user)
    ///   2. `apikey:<token>` HASH `{userId, role?}`   (long-lived; only source that may be admin)
    ///   3. Better Auth session: `session:idx:token:<token>` SET → sessionId,
    ///      `session:<id>` HASH `{userId, expiresAt}`. `isAnonymous` is read
    ///      from `user:<userId>.isAnonymous` (only meaningful for this source).
    /// Resource tokens never carry admin role; only apikey:<token> can.
    pub async fn resolve_identity(&self, token: &str) -> Result<Option<(String, String, bool)>> {
        let mut conn = self.conn();

        if let Some(user_id) = conn.get::<_, Option<String>>(format!("resource:token:{token}")).await? {
            return Ok(Some((user_id, "user".into(), false)));
        }

        let (user_id, role): (Option<String>, Option<String>) =
            conn.hget(format!("apikey:{token}"), &["userId", "role"][..]).await?;
        if let Some(uid) = user_id {
            return Ok(Some((uid, role.unwrap_or_else(|| "user".into()), false)));
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
        Ok(Some((uid, "user".into(), is_anon.as_deref() == Some("1"))))
    }

    // ── Sandbox inventory ─────────────────────────────────────────────────────

    /// Insert/replace a sandbox record, keep set memberships consistent, and
    /// publish the current state to `sandbox:events:<userId>` in the same
    /// MULTI/EXEC pipeline so subscribers never see a write without its event.
    /// Called on initial creation and after state transitions reached via
    /// direct `sandbox_put` (e.g. boot finish).
    pub async fn sandbox_put(&self, s: &Sandbox) -> Result<()> {
        let mut conn = self.conn();
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
        let mut conn = self.conn();
        let _: i64 = conn.incr("stats:sandbox:created", 1).await?;
        Ok(())
    }

    /// Read the lifetime-created counter.
    pub async fn sandbox_total_created(&self) -> Result<u64> {
        let mut conn = self.conn();
        let v: Option<String> = conn.get("stats:sandbox:created").await?;
        Ok(v.and_then(|s| s.parse().ok()).unwrap_or(0))
    }

    pub async fn sandbox_get(&self, id: &str) -> Result<Option<Sandbox>> {
        let mut conn = self.conn();
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
        let mut conn = self.conn();

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
        let mut conn = self.conn();

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
        let mut conn = self.conn();
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
        let mut conn = self.conn();
        let user_ids: std::collections::HashSet<String> =
            conn.smembers(format!("sandbox:user:{user_id}")).await?;
        let active_ids: std::collections::HashSet<String> =
            conn.smembers("sandbox:active").await?;
        Ok(user_ids.intersection(&active_ids).count())
    }

    /// All sandbox IDs currently in `sandbox:active`. Used for startup reconciliation.
    pub async fn sandbox_active_ids(&self) -> Result<Vec<String>> {
        let mut conn = self.conn();
        let ids: Vec<String> = conn.smembers("sandbox:active").await?;
        Ok(ids)
    }

    // ── Network IP allocation ────────────────────────────────────────────────
    //
    // Each allocated guest IP is owned by exactly one sandbox:
    //   sandbox:network:ip:<ipv4>   STRING (sandbox id)
    //
    // Claimed via `SET NX` so concurrent manager instances (blue-green deploy,
    // accidental dual-run) cannot double-allocate. Released on sandbox
    // teardown; rebuildable on startup from `sandbox:*` if the key range is
    // ever flushed.

    /// Claim an IP for a sandbox. Returns true if newly claimed, false if
    /// already taken (by this or any other sandbox).
    pub async fn ip_claim(&self, ip: std::net::Ipv4Addr, sandbox_id: &str) -> Result<bool> {
        let mut conn = self.conn();
        let res: Option<String> = redis::cmd("SET")
            .arg(format!("sandbox:network:ip:{ip}"))
            .arg(sandbox_id)
            .arg("NX")
            .query_async(&mut conn)
            .await
            .context("ip_claim SET NX failed")?;
        Ok(res.is_some())
    }

    /// Release an IP only if the caller still owns the claim. Prevents a
    /// late teardown from clobbering a freshly-reused IP. Idempotent.
    pub async fn ip_release_if_owner(&self, ip: std::net::Ipv4Addr, sandbox_id: &str) -> Result<()> {
        let mut conn = self.conn();
        let script = Script::new(
            r#"
            if redis.call('GET', KEYS[1]) == ARGV[1] then
              return redis.call('DEL', KEYS[1])
            end
            return 0
            "#,
        );
        let _: i64 = script
            .key(format!("sandbox:network:ip:{ip}"))
            .arg(sandbox_id)
            .invoke_async(&mut conn)
            .await
            .context("ip_release_if_owner script failed")?;
        Ok(())
    }

    /// Read the current owner of an IP claim, if any. For reconciliation /
    /// diagnostics — normal ops use compare-and-{claim,release}.
    pub async fn ip_claim_owner(&self, ip: std::net::Ipv4Addr) -> Result<Option<String>> {
        let mut conn = self.conn();
        let owner: Option<String> = conn.get(format!("sandbox:network:ip:{ip}")).await?;
        Ok(owner)
    }
}

/// Build RedisClient from DRAGONFLY_URL env var (shared with backend).
pub async fn connect_from_env() -> Result<RedisClient> {
    let url = std::env::var("DRAGONFLY_URL").context("DRAGONFLY_URL env var required")?;
    RedisClient::connect(&url).await
}
