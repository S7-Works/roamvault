use crate::AppState;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use sea_orm::{ConnectionTrait, Statement, DbBackend};
use std::sync::Arc;

pub async fn signed_url(
    State(state): State<Arc<AppState>>,
    Path(hash): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let row = state
        .db
        .query_one(Statement::from_string(
            DbBackend::Postgres,
            format!("SELECT b2_key FROM media_objects WHERE hash = '{}'", hash),
        ))
        .await
        .map_err(internal)?
        .ok_or((StatusCode::NOT_FOUND, "media not found".into()))?;

    let b2_key: String = row.try_get_by_index(0).map_err(internal)?;

    let url = state
        .b2
        .signed_download_url(&b2_key, 3600)
        .await
        .map_err(internal)?;

    Ok(Json(serde_json::json!({ "url": url })))
}

fn internal<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
