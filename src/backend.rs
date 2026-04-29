//! Backend client — calls todofor.ai admin REST endpoints.
//!
//! Used to mint short-lived, single-use enrollment tokens that are injected
//! into VMs at boot. The VM's bridge redeems the token once via
//! `cli.enroll.redeem` to get durable device credentials — the caller's own
//! API key never enters the VM.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Clone)]
pub struct BackendClient {
    base_url: String,
    admin_api_key: String,
    http: reqwest::Client,
}

#[derive(Serialize)]
struct MintRequest<'a> {
    #[serde(rename = "userId")]
    user_id: &'a str,
    #[serde(rename = "ttlSec", skip_serializing_if = "Option::is_none")]
    ttl_sec: Option<u32>,
}

#[derive(Deserialize)]
pub struct MintResponse {
    pub token: String,
}

#[derive(Serialize)]
struct RedeemRequest<'a> {
    token: &'a str,
    identity: Value,
}

#[derive(Deserialize)]
struct RedeemResponseDevice {
    id: String,
}

#[derive(Deserialize)]
struct RedeemResponse {
    device: RedeemResponseDevice,
}

impl BackendClient {
    /// Build from env vars. Both BACKEND_URL and BACKEND_ADMIN_API_KEY are required.
    pub fn from_env() -> Result<Self> {
        let base_url = std::env::var("BACKEND_URL")
            .context("BACKEND_URL not set")?;
        let admin_api_key = std::env::var("BACKEND_ADMIN_API_KEY")
            .context("BACKEND_ADMIN_API_KEY not set")?;
        Self::new(base_url, admin_api_key)
    }

    pub fn new(base_url: String, admin_api_key: String) -> Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .context("Failed to build HTTP client")?;
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            admin_api_key,
            http,
        })
    }

    /// Mint a fresh enrollment token for `user_id`. Short-lived, single-use.
    pub async fn mint_enroll_token(&self, user_id: &str, ttl_sec: Option<u32>) -> Result<MintResponse> {
        let url = format!("{}/admin/v1/enroll/mint", self.base_url);
        let resp = self
            .http
            .post(&url)
            .header("X-API-Key", &self.admin_api_key)
            .json(&MintRequest { user_id, ttl_sec })
            .send()
            .await
            .context("mint request failed")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            bail!("mint failed: {} {}", status, body);
        }

        Ok(resp.json().await.context("mint response decode failed")?)
    }

    /// Materialize a Device row for a Lite sandbox (no bridge process inside).
    /// Mints + redeems an enrollment token on behalf of the sandbox so it goes
    /// through the exact same path as a real bridge enrollment. Returns the
    /// new device id, which we persist on the sandbox for cleanup.
    pub async fn create_lite_sandbox_device(
        &self,
        user_id: &str,
        sandbox_id: &str,
        hostname: &str,
        token_ttl_sec: u32,
    ) -> Result<String> {
        let token = self.mint_enroll_token(user_id, Some(token_ttl_sec)).await
            .context("mint enroll token for lite sandbox")?
            .token;

        let identity = json!({
            "deviceType":  "SANDBOX",
            "sandboxId":   sandbox_id,
            "sandboxKind": "lite",
            "hostname":    hostname,
        });

        // Public, no-auth route — token is the capability.
        let url = format!("{}/api/v1/cli/enroll/redeem", self.base_url);
        let resp = self
            .http
            .post(&url)
            .json(&RedeemRequest { token: &token, identity })
            .send()
            .await
            .context("redeem request failed")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            bail!("redeem failed: {} {}", status, body);
        }

        let r: RedeemResponse = resp.json().await.context("redeem response decode failed")?;
        Ok(r.device.id)
    }

    /// Delete a Device row by id. Uses the standard admin device-delete endpoint
    /// with `X-User-Id` for ownership. Idempotent (404 ⇒ Ok).
    pub async fn delete_device(&self, user_id: &str, device_id: &str) -> Result<()> {
        let url = format!("{}/admin/v1/devices/{}", self.base_url, device_id);
        let resp = self
            .http
            .delete(&url)
            .header("X-API-Key", &self.admin_api_key)
            .header("X-User-Id", user_id)
            .send()
            .await
            .context("delete_device request failed")?;

        if !resp.status().is_success() && resp.status().as_u16() != 404 {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            bail!("delete_device failed: {} {}", status, body);
        }
        Ok(())
    }
}
