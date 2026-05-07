mod db;
mod models;
mod parser;
mod routes;
mod storage;

use anyhow::Result;
use axum::{Router, routing::{delete, get, post}};
use dotenvy::dotenv;
use sea_orm::Database;
use std::sync::Arc;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

pub struct AppState {
    pub db: sea_orm::DatabaseConnection,
    pub b2: storage::B2Client,
}

#[tokio::main]
async fn main() -> Result<()> {
    dotenv().ok();

    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let db_url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let db = Database::connect(&db_url).await?;

    db::run_migrations(&db).await?;

    let b2 = storage::B2Client::new(
        std::env::var("B2_KEY_ID").expect("B2_KEY_ID must be set"),
        std::env::var("B2_APP_KEY").expect("B2_APP_KEY must be set"),
        std::env::var("B2_BUCKET_NAME").expect("B2_BUCKET_NAME must be set"),
    );

    let state = Arc::new(AppState { db, b2 });

    let app = Router::new()
        .route("/upload/whatsapp", post(routes::upload::whatsapp))
        .route("/upload/media", post(routes::upload::media))
        .route("/view/:id", get(routes::view::serve_viewer))
        .route("/api/chat/:id/messages", get(routes::chat::messages))
        .route("/api/media/:hash", get(routes::media::signed_url))
        .route("/api/storage/stats", get(routes::storage::stats))
        .route("/chat/:id", delete(routes::chat::delete_chat))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = std::env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into());
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!("listening on {addr}");
    axum::serve(listener, app).await?;

    Ok(())
}
