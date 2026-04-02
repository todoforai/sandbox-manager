/// Redis client — mirrors the key schema from backend/src/redis/
///
/// Key schema (same as backend):
///   apikey:<token>          HASH  { userId, ... }
///   appuser:<userId>        HASH  { balance, subscriptionBalance, manualBalance, subscriptionUsageThisMonth, ... }
///   resource:token:<token>  STRING userId  (short-lived, TTL 2h)

use anyhow::{Context, Result};
use redis::{aio::MultiplexedConnection, AsyncCommands, Client, Script};
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Clone)]
pub struct RedisClient {
    inner: Arc<RwLock<Option<MultiplexedConnection>>>,
    url: String,
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
            url: url.to_string(),
        })
    }

    async fn conn(&self) -> Result<MultiplexedConnection> {
        let guard = self.inner.read().await;
        guard.clone().context("Redis not connected")
    }

    /// Resolve API key or resource token → userId.
    /// Checks resource:token:<token> first (short-lived), then apikey:<token>.
    pub async fn resolve_token(&self, token: &str) -> Result<Option<String>> {
        let mut conn = self.conn().await?;

        // 1. Short-lived resource token
        if let Some(user_id) = conn.get::<_, Option<String>>(format!("resource:token:{}", token)).await? {
            return Ok(Some(user_id));
        }

        // 2. API key hash
        let user_id: Option<String> = conn.hget(format!("apikey:{}", token), "userId").await?;
        Ok(user_id)
    }

    /// Check if user has enough balance to cover at least `minimum`.
    pub async fn has_balance(&self, user_id: &str, minimum: f64) -> Result<bool> {
        let mut conn = self.conn().await?;
        let raw: Option<String> = conn.hget(format!("appuser:{}", user_id), "balance").await?;
        let balance: f64 = raw.as_deref().unwrap_or("0").parse().unwrap_or(0.0);
        Ok(balance > minimum)
    }

    /// Atomically deduct `amount` from user balance.
    /// Drains subscriptionBalance first, overflows to manualBalance.
    /// Returns new total balance.
    pub async fn deduct_balance(&self, user_id: &str, amount: f64) -> Result<f64> {
        let mut conn = self.conn().await?;
        let script = Script::new(
            r#"
            local key = KEYS[1]
            local amount = tonumber(ARGV[1])
            local subBal = tonumber(redis.call('HGET', key, 'subscriptionBalance') or '0')
            local manBal = tonumber(redis.call('HGET', key, 'manualBalance') or '0')
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
            .key(format!("appuser:{}", user_id))
            .arg(amount.to_string())
            .invoke_async(&mut conn)
            .await
            .context("deduct_balance script failed")?;
        Ok(new_balance.parse().unwrap_or(0.0))
    }
}

/// Build RedisClient from DRAGONFLY_URL env var (same name as backend/resource-gateway).
pub async fn connect_from_env() -> Result<RedisClient> {
    let url = std::env::var("DRAGONFLY_URL").context("DRAGONFLY_URL env var required")?;
    RedisClient::connect(&url).await
}
