//! Redis client — Redis is the source of truth for:
//!   - Identity & billing (`apikey:*`, `resource:token:*`, `appuser:*`) — writer: backend
//!   - Sandbox inventory (`sandbox:*`) — writer: this service
//!
//! Inventory key schema:
//!   sandbox:<id>                STRING (JSON of Sandbox)
//!   sandbox:all                 SET    every sandbox ID (any state)
//!   sandbox:user:<userId>       SET    sandbox IDs owned by user (any state)
//!   sandbox:active              SET    sandbox IDs currently Running or Paused
//!   stats:sandbox:created       COUNTER  monotonic lifetime counter

use anyhow::{Context, Result};
use redis::{aio::MultiplexedConnection, AsyncCommands, Client, Script};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::vm::sandbox::{Sandbox, SandboxState};

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

    /// Resolve token → (userId, role). Role defaults to "user".
    /// Resource tokens never carry admin role; only apikey:<token> can have role=admin.
    pub async fn resolve_identity(&self, token: &str) -> Result<Option<(String, String)>> {
        let mut conn = self.conn().await?;

        if let Some(user_id) = conn.get::<_, Option<String>>(format!("resource:token:{token}")).await? {
            return Ok(Some((user_id, "user".into())));
        }

        let (user_id, role): (Option<String>, Option<String>) =
            conn.hget(format!("apikey:{token}"), &["userId", "role"][..]).await?;
        match user_id {
            Some(uid) => Ok(Some((uid, role.unwrap_or_else(|| "user".into())))),
            None => Ok(None),
        }
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

    /// Insert a new sandbox and update all set memberships atomically.
    /// Called on initial creation.
    pub async fn sandbox_put(&self, s: &Sandbox) -> Result<()> {
        let mut conn = self.conn().await?;
        let json = serde_json::to_string(s).context("serialize sandbox")?;
        let script = Script::new(
            r#"
            redis.call('SET', KEYS[1], ARGV[1])
            redis.call('SADD', KEYS[2], ARGV[2])
            redis.call('SADD', KEYS[3], ARGV[2])
            if ARGV[3] == '1' then
                redis.call('SADD', KEYS[4], ARGV[2])
            else
                redis.call('SREM', KEYS[4], ARGV[2])
            end
            return 1
            "#,
        );
        script
            .key(format!("sandbox:{}", s.id))
            .key("sandbox:all".to_string())
            .key(format!("sandbox:user:{}", s.user_id))
            .key("sandbox:active".to_string())
            .arg(json)
            .arg(&s.id)
            .arg(if s.is_active() { "1" } else { "0" })
            .invoke_async::<i64>(&mut conn)
            .await
            .context("sandbox_put script failed")?;
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

    /// Atomically update state (and optionally error). Active set membership
    /// is maintained in the same script so reads are race-free. If the record
    /// was concurrently deleted, this is a no-op.
    pub async fn sandbox_set_state(&self, id: &str, state: SandboxState, error: Option<&str>) -> Result<()> {
        let mut conn = self.conn().await?;
        let state_json = serde_json::to_string(&state).unwrap_or_else(|_| "\"error\"".into());
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let is_active = matches!(state, SandboxState::Running | SandboxState::Paused);

        let script = Script::new(
            r#"
            local raw = redis.call('GET', KEYS[1])
            if not raw then return 0 end
            local obj = cjson.decode(raw)
            obj.state = cjson.decode(ARGV[1])
            if ARGV[2] ~= '' then obj.error = ARGV[2] end
            obj.last_activity = tonumber(ARGV[3])
            redis.call('SET', KEYS[1], cjson.encode(obj))
            if ARGV[4] == '1' then
                redis.call('SADD', KEYS[2], ARGV[5])
            else
                redis.call('SREM', KEYS[2], ARGV[5])
            end
            return 1
            "#,
        );
        script
            .key(format!("sandbox:{id}"))
            .key("sandbox:active".to_string())
            .arg(state_json)
            .arg(error.unwrap_or(""))
            .arg(now_ms.to_string())
            .arg(if is_active { "1" } else { "0" })
            .arg(id)
            .invoke_async::<i64>(&mut conn)
            .await
            .context("sandbox_set_state script failed")?;
        Ok(())
    }

    /// Remove sandbox and all set memberships atomically.
    pub async fn sandbox_delete(&self, id: &str) -> Result<()> {
        let mut conn = self.conn().await?;
        let script = Script::new(
            r#"
            local raw = redis.call('GET', KEYS[1])
            if not raw then return 0 end
            local obj = cjson.decode(raw)
            redis.call('DEL', KEYS[1])
            redis.call('SREM', KEYS[2], ARGV[1])
            redis.call('SREM', KEYS[3], ARGV[1])
            redis.call('SREM', 'sandbox:user:' .. obj.user_id, ARGV[1])
            return 1
            "#,
        );
        script
            .key(format!("sandbox:{id}"))
            .key("sandbox:all".to_string())
            .key("sandbox:active".to_string())
            .arg(id)
            .invoke_async::<i64>(&mut conn)
            .await
            .context("sandbox_delete script failed")?;
        Ok(())
    }

    async fn hydrate(&self, ids: Vec<String>) -> Result<Vec<Sandbox>> {
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(s) = self.sandbox_get(&id).await? { out.push(s); }
        }
        Ok(out)
    }

    /// List every sandbox (or just a user's). Any state.
    pub async fn sandbox_list(&self, user_id: Option<&str>) -> Result<Vec<Sandbox>> {
        let mut conn = self.conn().await?;
        let ids: Vec<String> = match user_id {
            Some(uid) => conn.smembers(format!("sandbox:user:{uid}")).await?,
            None => conn.smembers("sandbox:all").await?,
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
