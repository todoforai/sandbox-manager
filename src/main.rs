mod api;      // REST adapter
mod auth;     // token → AuthIdentity
mod backend;  // HTTP client for todofor.ai admin endpoints
mod noise;    // Noise/TCP adapter
mod redis;    // Redis client (auth + billing)
mod service;  // transport-agnostic sandbox service
mod vm;
mod template;

use anyhow::Result;
use axum::{routing::{get, post, delete}, Router};
use std::sync::Arc;
use tower_http::cors::CorsLayer;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

use crate::service::SandboxService;
use crate::vm::manager::VmManager;

#[tokio::main]
async fn main() -> Result<()> {
    // NODE_ENV=production → .env, otherwise .env.development.
    // Both files are committed; .env.template documents the schema.
    let env_file = if std::env::var("NODE_ENV").as_deref() == Ok("production") {
        ".env"
    } else {
        ".env.development"
    };
    dotenvy::from_filename(env_file).ok();

    // Subcommands (run before tracing init so output is clean):
    //   sandbox-manager keygen   — print a new Noise static keypair (hex)
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|s| s.as_str()) == Some("keygen") {
        let kp = noise::server::generate_static_keypair()?;
        println!("NOISE_LOCAL_PRIVATE_KEY={}", hex_encode(&kp.private));
        println!("NOISE_LOCAL_PUBLIC_KEY={}", hex_encode(&kp.public));
        return Ok(());
    }

    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "sandbox_manager=debug,info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    // Redis is required — it stores the sandbox inventory and resolves identities.
    let redis = redis::connect_from_env().await?;

    let config = vm::config::ManagerConfig::from_env();
    let manager = Arc::new(VmManager::new(config, redis.clone()).await?);

    let backend = match backend::BackendClient::from_env()? {
        Some(c) => { tracing::info!("Backend client configured"); Some(c) }
        None => {
            tracing::warn!("BACKEND_URL / BACKEND_ADMIN_API_KEY not set — enroll token minting disabled; VMs will boot without bridge auth");
            None
        }
    };

    let service = SandboxService::new(manager.clone(), redis, backend);

    // Spawn idle cleanup task
    let cleanup_manager = manager.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            cleanup_manager.cleanup_idle(300).await; // 5 min idle timeout
        }
    });

    // Spawn Noise/TCP adapter on a separate port.
    // Env: NOISE_BIND_ADDR=0.0.0.0:9010
    //      NOISE_LOCAL_PRIVATE_KEY=<32-byte hex>
    let noise_service = service.clone();
    tokio::spawn(async move {
        if let Err(err) = noise::server::serve(noise_service).await {
            tracing::error!("Noise server failed: {}", err);
        }
    });

    let app = Router::new()
        // Health & Stats
        .route("/health", get(api::health::health))
        .route("/stats", get(api::sandbox::get_stats))
        
        // Sandbox lifecycle
        .route("/sandbox", get(api::sandbox::list_sandboxes).post(api::sandbox::create_sandbox))
        .route("/sandbox/:id", get(api::sandbox::get_sandbox))
        .route("/sandbox/:id", delete(api::sandbox::delete_sandbox))
        .route("/sandbox/:id/pause", post(api::sandbox::pause_sandbox))
        .route("/sandbox/:id/resume", post(api::sandbox::resume_sandbox))
        .route("/sandbox/:id/balloon", post(api::sandbox::balloon_sandbox))
        
        // Templates
        .route("/templates", get(api::templates::list_templates))
        .route("/templates/:name", post(api::templates::create_template))
        
        .layer(CorsLayer::permissive())
        .with_state(service);

    let addr = std::env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:9000".into());
    tracing::info!("Sandbox manager listening on {}", addr);
    
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}
