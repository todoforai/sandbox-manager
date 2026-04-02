mod api;      // REST adapter
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
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "sandbox_manager=debug,info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let config = vm::config::ManagerConfig::from_env();
    let manager = Arc::new(VmManager::new(config).await?);

    let redis = match redis::connect_from_env().await {
        Ok(r) => { tracing::info!("Redis connected"); Some(r) }
        Err(e) => { tracing::warn!("Redis unavailable (auth disabled): {}", e); None }
    };

    let service = SandboxService::new(manager.clone(), redis);

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
    // Env: NOISE_BIND_ADDR=0.0.0.0:9001
    //      NOISE_LOCAL_PRIVATE_KEY=<32-byte hex>
    //      NOISE_REMOTE_PUBLIC_KEY=<32-byte hex>
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
