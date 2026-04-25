//! Backend client — calls todofor.ai admin REST endpoints.
//!
//! Used to mint short-lived, single-use enrollment tokens that are injected
//! into VMs at boot. The VM's bridge redeems the token once via
//! `cli.enroll.redeem` to get durable device credentials — the caller's own
//! API key never enters the VM.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

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
    #[serde(rename = "expiresIn")]
    pub expires_in: u32,
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
}
