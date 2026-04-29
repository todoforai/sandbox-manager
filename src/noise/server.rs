use anyhow::{anyhow, Context, Result};
use serde_json::json;
use snow::{params::NoiseParams, Builder, Keypair, TransportState};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::auth::{authenticate, AuthIdentity};
use crate::noise::protocol::{self, CreateSandboxPayload, CreateTemplateRequest, IdPayload, ListPayload, NoiseRequest};
use crate::service::errors::ErrorCode;
use crate::service::SandboxService;
use crate::vm::config::TemplateConfig;

const MAX_FRAME: usize = 1024 * 1024;
const NOISE_PATTERN: &str = "Noise_NX_25519_ChaChaPoly_BLAKE2b";

pub async fn serve(service: SandboxService) -> Result<()> {
    let addr = std::env::var("NOISE_BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:9010".into());
    let listener = TcpListener::bind(&addr).await?;
    tracing::info!("Sandbox manager Noise listening on {}", addr);

    let service = Arc::new(service);
    loop {
        let (stream, peer) = listener.accept().await?;
        let service = service.clone();
        tokio::spawn(async move {
            if let Err(err) = handle_conn(stream, service).await {
                tracing::warn!("Noise connection {} failed: {}", peer, err);
            }
        });
    }
}

async fn handle_conn(mut stream: TcpStream, service: Arc<SandboxService>) -> Result<()> {
    let mut noise = handshake_responder(&mut stream).await?;
    loop {
        let req = match read_message(&mut stream, &mut noise).await {
            Ok(req) => req,
            Err(err) if is_eof(&err) => return Ok(()),
            Err(err) => return Err(err),
        };
        let res = dispatch(&service, req).await;
        write_message(&mut stream, &mut noise, &serde_json::to_vec(&res)?).await?;
    }
}

/// Methods that do not require auth.
fn is_public(kind: &str) -> bool {
    matches!(kind, "health.get" | "templates.list")
}

async fn resolve_identity(
    service: &SandboxService,
    token: Option<&str>,
) -> Result<AuthIdentity, String> {
    let token = token.ok_or_else(|| "missing token".to_string())?;
    authenticate(service.redis(), token).await.map_err(|e| e.to_string())
}

async fn dispatch(service: &SandboxService, req: NoiseRequest) -> protocol::NoiseResponse {
    use protocol::{err, ok, parse};

    // Public methods skip auth.
    if is_public(&req.kind) {
        return match req.kind.as_str() {
            "health.get" => ok(req.id, json!({ "status": "ok", "version": env!("CARGO_PKG_VERSION") })),
            "templates.list" => ok(req.id, service.list_templates()),
            _ => unreachable!(),
        };
    }

    // Authenticate.
    let identity = match resolve_identity(service, req.token.as_deref()).await {
        Ok(id) => id,
        Err(e) => return err(req.id, ErrorCode::Unauthorized, e),
    };

    match req.kind.as_str() {
        "stats.get" => match service.stats().await {
            Ok(s) => ok(req.id, s),
            Err(e) => err(req.id, ErrorCode::Internal, e.to_string()),
        },
        "sandbox.list" => match parse::<ListPayload>(req.payload) {
            Ok(payload) => match service.list_sandboxes(&identity, payload.user_id.as_deref()).await {
                Ok(list) => ok(req.id, list),
                Err(e) => err(req.id, ErrorCode::Internal, e.to_string()),
            },
            Err(e) => err(req.id, ErrorCode::BadRequest, e),
        },
        "sandbox.get" => match parse::<IdPayload>(req.payload) {
            Ok(payload) => match service.get_sandbox(&identity, &payload.id).await {
                Ok(Some(sandbox)) => ok(req.id, sandbox),
                Ok(None) => err(req.id, ErrorCode::NotFound, "Sandbox not found"),
                Err(e) => err(req.id, ErrorCode::Internal, e.to_string()),
            },
            Err(e) => err(req.id, ErrorCode::BadRequest, e),
        },
        "sandbox.create" => match parse::<CreateSandboxPayload>(req.payload) {
            Ok(payload) => match service.create_sandbox(&identity, payload).await {
                Ok(sandbox) => ok(req.id, sandbox),
                Err(e) => err(req.id, ErrorCode::Internal, e.to_string()),
            },
            Err(e) => err(req.id, ErrorCode::BadRequest, e),
        },
        "sandbox.delete" => match parse::<IdPayload>(req.payload) {
            Ok(payload) => match service.delete_sandbox(&identity, &payload.id).await {
                Ok(()) => ok(req.id, json!({ "deleted": true })),
                Err(e) => err(req.id, ErrorCode::Forbidden, e.to_string()),
            },
            Err(e) => err(req.id, ErrorCode::BadRequest, e),
        },
        "sandbox.pause" => match parse::<IdPayload>(req.payload) {
            Ok(payload) => match service.pause_sandbox(&identity, &payload.id).await {
                Ok(()) => ok(req.id, json!({ "paused": true })),
                Err(e) => err(req.id, ErrorCode::BadRequest, e.to_string()),
            },
            Err(e) => err(req.id, ErrorCode::BadRequest, e),
        },
        "sandbox.resume" => match parse::<IdPayload>(req.payload) {
            Ok(payload) => match service.resume_sandbox(&identity, &payload.id).await {
                Ok(()) => ok(req.id, json!({ "resumed": true })),
                Err(e) => err(req.id, ErrorCode::BadRequest, e.to_string()),
            },
            Err(e) => err(req.id, ErrorCode::BadRequest, e),
        },

        "template.create" => {
            if !identity.is_admin() {
                return err(req.id, ErrorCode::Forbidden, "admin role required");
            }
            match parse::<CreateTemplateRequest>(req.payload) {
                Ok(payload) => {
                    let config = TemplateConfig {
                        name: payload.name.clone(),
                        kernel_path: payload.kernel_path.into(),
                        rootfs_path: payload.rootfs_path.into(),
                        boot_args: payload.boot_args.unwrap_or_else(|| "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/sbin/init".into()),
                        description: payload.description.unwrap_or_default(),
                        packages: payload.packages.unwrap_or_default(),
                        ..Default::default()
                    };
                    match service.load_template(&payload.name, &config).await {
                        Ok(()) => ok(req.id, json!({ "created": true })),
                        Err(e) => err(req.id, ErrorCode::Internal, e.to_string()),
                    }
                }
                Err(e) => err(req.id, ErrorCode::BadRequest, e),
            }
        }
        _ => err(req.id, ErrorCode::NotImplemented, format!("Unknown request type: {}", req.kind)),
    }
}

async fn handshake_responder(stream: &mut TcpStream) -> Result<TransportState> {
    let params: NoiseParams = NOISE_PATTERN.parse()?;
    let local_private = load_local_private_key()?;
    let builder = Builder::new(params).local_private_key(&local_private);
    let mut state = builder.build_responder()?;

    let mut in_buf = vec![0u8; MAX_FRAME];
    let msg = read_frame(stream).await?;
    let _ = state.read_message(&msg, &mut in_buf)?;

    let mut out_buf = vec![0u8; MAX_FRAME];
    let len = state.write_message(&[], &mut out_buf)?;
    write_frame(stream, &out_buf[..len]).await?;

    Ok(state.into_transport_mode()?)
}

async fn read_message(stream: &mut TcpStream, noise: &mut TransportState) -> Result<NoiseRequest> {
    let msg = read_frame(stream).await?;
    let mut out = vec![0u8; MAX_FRAME];
    let len = noise.read_message(&msg, &mut out)?;
    serde_json::from_slice(&out[..len]).context("invalid request json")
}

async fn write_message(stream: &mut TcpStream, noise: &mut TransportState, plain: &[u8]) -> Result<()> {
    let mut out = vec![0u8; plain.len() + 64];
    let len = noise.write_message(plain, &mut out)?;
    write_frame(stream, &out[..len]).await
}

async fn read_frame(stream: &mut TcpStream) -> Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(anyhow!("invalid frame length: {}", len));
    }
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf).await?;
    Ok(buf)
}

async fn write_frame(stream: &mut TcpStream, data: &[u8]) -> Result<()> {
    let len = u32::try_from(data.len()).context("frame too large")?;
    stream.write_all(&len.to_be_bytes()).await?;
    stream.write_all(data).await?;
    Ok(())
}

fn is_eof(err: &anyhow::Error) -> bool {
    err.downcast_ref::<std::io::Error>()
        .map(|e| e.kind() == std::io::ErrorKind::UnexpectedEof)
        .unwrap_or(false)
}

fn load_local_private_key() -> Result<Vec<u8>> {
    decode_key_env("NOISE_LOCAL_PRIVATE_KEY", "responder private key")
}


fn decode_key_env(name: &str, label: &str) -> Result<Vec<u8>> {
    let value = std::env::var(name)
        .with_context(|| format!("missing {label} env var: {name}"))?;
    let bytes = decode_hex(value.trim())
        .with_context(|| format!("invalid hex in {name}"))?;
    if bytes.len() != 32 {
        return Err(anyhow!("{name} must be 32 bytes hex"));
    }
    Ok(bytes)
}

fn decode_hex(s: &str) -> Result<Vec<u8>> {
    if s.len() % 2 != 0 {
        return Err(anyhow!("hex length must be even"));
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| anyhow!(e)))
        .collect()
}

#[allow(dead_code)]
fn generate_keypair() -> Result<Keypair> {
    let params: NoiseParams = NOISE_PATTERN.parse()?;
    Ok(Builder::new(params).generate_keypair()?)
}

/// Public entrypoint used by the `keygen` subcommand.
pub fn generate_static_keypair() -> Result<Keypair> {
    generate_keypair()
}
