//! SSH recovery channel: signs short-lived user certs that grant access to
//! a single sandbox's `recovery` user over the vsock SSH listener.
//!
//! Trust model:
//!   - One platform CA (ed25519). Its public key is baked into every VM
//!     rootfs as `/etc/ssh/recovery_ca.pub` and configured via
//!     `TrustedUserCAKeys`. Private key lives only inside sandbox-manager.
//!   - Each issued cert has a single principal `recovery:<sandbox-id>`.
//!     `/etc/ssh/auth_principals/recovery` inside the guest is rendered at
//!     boot to contain exactly that one line, so a cert minted for sandbox
//!     A is rejected by sandbox B even though both trust the same CA.
//!   - Cert validity is short (default 600s); the manager controls every
//!     cert field — clients only supply the public key to be signed.
//!
//! Storage: CA private key path is `RECOVERY_CA_PATH`
//! (default `$DATA_DIR/recovery_ca`), in OpenSSH private-key format.
//! Auto-generated on first start if missing.

use anyhow::{Context, Result};
use rand::RngCore;
use ssh_key::{
    certificate::{Builder as CertBuilder, CertType},
    private::{Ed25519Keypair, PrivateKey},
    PublicKey,
};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Default cert lifetime if caller doesn't specify. Long enough for a slow
/// network and a poke-around session, short enough that leaked certs decay
/// fast without rotation.
pub const DEFAULT_CERT_TTL_SECS: u64 = 600;

/// Hard cap so a buggy or malicious caller can't ask for a year-long cert.
pub const MAX_CERT_TTL_SECS: u64 = 3600;

#[derive(Clone)]
pub struct RecoveryCa {
    /// CA private key in memory. ssh-key zeroizes on drop.
    key: PrivateKey,
    /// Cached OpenSSH-format public key string for guest provisioning.
    pub_openssh: String,
}

impl RecoveryCa {
    /// Load the CA from `path`, generating a fresh ed25519 key if the file
    /// doesn't exist. File is written with mode 0600.
    pub fn load_or_init(path: &Path) -> Result<Self> {
        if path.exists() {
            let pem = std::fs::read_to_string(path)
                .with_context(|| format!("read CA key {}", path.display()))?;
            let key = PrivateKey::from_openssh(pem)
                .with_context(|| format!("parse CA key {}", path.display()))?;
            let pub_openssh = key.public_key().to_openssh()
                .context("encode CA public key")?;
            tracing::info!("loaded recovery CA from {}", path.display());
            Ok(Self { key, pub_openssh })
        } else {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).ok();
            }
            let mut rng = rand::thread_rng();
            let kp = Ed25519Keypair::random(&mut rng);
            let key = PrivateKey::from(kp);
            let pem = key.to_openssh(ssh_key::LineEnding::LF)
                .context("encode CA private key")?;
            // Write 0600 atomically.
            use std::os::unix::fs::OpenOptionsExt;
            let mut f = std::fs::OpenOptions::new()
                .write(true).create_new(true).mode(0o600)
                .open(path)
                .with_context(|| format!("create CA key {}", path.display()))?;
            std::io::Write::write_all(&mut f, pem.as_bytes())?;
            let pub_openssh = key.public_key().to_openssh()
                .context("encode CA public key")?;
            tracing::warn!("generated NEW recovery CA at {} — bake its public key into rootfs", path.display());
            Ok(Self { key, pub_openssh })
        }
    }

    /// Public key in `ssh-ed25519 AAAA... comment` form. Drop into
    /// `/etc/ssh/recovery_ca.pub` in the guest rootfs.
    pub fn authorized_key_line(&self) -> &str {
        &self.pub_openssh
    }

    /// Sign `user_pubkey` as a recovery cert valid for `ttl_secs` seconds,
    /// scoped to a single sandbox via the principal `recovery:<sandbox_id>`.
    /// Returns the cert in OpenSSH text form (one line).
    /// Returns `(cert_openssh, effective_ttl_secs)` — TTL is clamped, so
    /// callers must use the returned value when reporting back to the user.
    pub fn sign_recovery_cert(
        &self,
        user_pubkey_openssh: &str,
        sandbox_id: &str,
        caller_id: &str,
        ttl_secs: u64,
    ) -> Result<(String, u64)> {
        let ttl = ttl_secs.clamp(30, MAX_CERT_TTL_SECS);
        let user_pub = PublicKey::from_openssh(user_pubkey_openssh.trim())
            .context("parse client public key")?;

        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        // Allow 60s clock skew on the not-before bound.
        let valid_after = now.saturating_sub(60);
        let valid_before = now + ttl;

        // Random 64-bit serial so log correlation is unique per issuance.
        let mut serial_buf = [0u8; 8];
        rand::thread_rng().fill_bytes(&mut serial_buf);
        let serial = u64::from_be_bytes(serial_buf);

        let key_id = format!(
            "sandbox={sandbox_id} caller={caller_id} purpose=recovery serial={serial:016x}"
        );

        let mut builder = CertBuilder::new_with_random_nonce(
            &mut rand::thread_rng(),
            &user_pub,
            valid_after,
            valid_before,
        )?;
        builder.serial(serial)?
            .key_id(key_id.clone())?
            .cert_type(CertType::User)?
            .valid_principal(format!("recovery:{sandbox_id}"))?
            // No port-forwarding / agent-forwarding / X11 / pty escalation.
            // pty is required for an interactive shell; allow it.
            .extension("permit-pty", "")?;

        let cert = builder.sign(&self.key).context("sign recovery cert")?;
        let line = cert.to_openssh().context("encode cert")?;
        tracing::info!(
            "issued recovery cert: {} (ttl={}s, valid_before={})",
            key_id, ttl, valid_before
        );
        Ok((line, ttl))
    }
}

/// Resolve CA key path from env, defaulting under `DATA_DIR`.
pub fn default_ca_path() -> PathBuf {
    if let Ok(p) = std::env::var("RECOVERY_CA_PATH") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
    let data_dir = std::env::var("DATA_DIR").unwrap_or_else(|_| format!("{home}/sandbox-data"));
    PathBuf::from(format!("{data_dir}/recovery_ca"))
}
