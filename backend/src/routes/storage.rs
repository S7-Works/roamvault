use crate::{models::StorageStats, AppState};
use axum::{extract::State, http::StatusCode, Json};
use sea_orm::{ConnectionTrait, Statement, DbBackend};
use std::sync::Arc;

pub async fn stats(
    State(state): State<Arc<AppState>>,
) -> Result<Json<StorageStats>, (StatusCode, String)> {
    let chats: i64 = state
        .db
        .query_one(Statement::from_string(
            DbBackend::Postgres,
            "SELECT COUNT(*) FROM chats".to_owned(),
        ))
        .await
        .map_err(internal)?
        .map(|r| r.try_get_by_index::<i64>(0).unwrap_or(0))
        .unwrap_or(0);

    let messages: i64 = state
        .db
        .query_one(Statement::from_string(
            DbBackend::Postgres,
            "SELECT COUNT(*) FROM messages".to_owned(),
        ))
        .await
        .map_err(internal)?
        .map(|r| r.try_get_by_index::<i64>(0).unwrap_or(0))
        .unwrap_or(0);

    let media_bytes: i64 = state
        .db
        .query_one(Statement::from_string(
            DbBackend::Postgres,
            "SELECT COALESCE(SUM(size_bytes), 0) FROM media_objects".to_owned(),
        ))
        .await
        .map_err(internal)?
        .map(|r| r.try_get_by_index::<i64>(0).unwrap_or(0))
        .unwrap_or(0);

    let unique_objects: i64 = state
        .db
        .query_one(Statement::from_string(
            DbBackend::Postgres,
            "SELECT COUNT(*) FROM media_objects".to_owned(),
        ))
        .await
        .map_err(internal)?
        .map(|r| r.try_get_by_index::<i64>(0).unwrap_or(0))
        .unwrap_or(0);

    Ok(Json(StorageStats {
        total_chats: chats,
        total_messages: messages,
        total_media_bytes: media_bytes,
        unique_media_objects: unique_objects,
    }))
}

fn internal<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
