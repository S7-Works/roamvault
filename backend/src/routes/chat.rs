use crate::{models::MessageChunk, AppState};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use sea_orm::{ConnectionTrait, Statement, DbBackend};
use serde::Deserialize;
use std::sync::Arc;

#[derive(Deserialize)]
pub struct ChunkQuery {
    chunk: Option<i32>,
}

pub async fn messages(
    State(state): State<Arc<AppState>>,
    Path(chat_id): Path<String>,
    Query(q): Query<ChunkQuery>,
) -> Result<Json<MessageChunk>, (StatusCode, String)> {
    let chunk_index = q.chunk.unwrap_or(0);

    let row = state
        .db
        .query_one(Statement::from_string(
            DbBackend::Postgres,
            format!(
                "SELECT b2_key, message_count FROM b2_chunks \
                 WHERE chat_id = '{}' AND chunk_index = {} LIMIT 1",
                chat_id, chunk_index
            ),
        ))
        .await
        .map_err(internal)?
        .ok_or((StatusCode::NOT_FOUND, "chunk not found".into()))?;

    let b2_key: String = row.try_get_by_index(0).map_err(internal)?;

    let total_chunks: i64 = state
        .db
        .query_one(Statement::from_string(
            DbBackend::Postgres,
            format!(
                "SELECT COUNT(*) FROM b2_chunks WHERE chat_id = '{}'",
                chat_id
            ),
        ))
        .await
        .map_err(internal)?
        .map(|r| r.try_get_by_index::<i64>(0).unwrap_or(1))
        .unwrap_or(1);

    let signed_url = state
        .b2
        .signed_download_url(&b2_key, 300)
        .await
        .map_err(internal)?;

    let compressed = reqwest::get(&signed_url)
        .await
        .map_err(internal)?
        .bytes()
        .await
        .map_err(internal)?;

    let decompressed = brotli_decompress(&compressed).map_err(internal)?;
    let messages: Vec<crate::models::MessageView> =
        serde_json::from_slice(&decompressed).map_err(internal)?;

    Ok(Json(MessageChunk {
        messages,
        chunk_index,
        total_chunks: total_chunks as i32,
    }))
}

pub async fn delete_chat(
    State(state): State<Arc<AppState>>,
    Path(chat_id): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    // get user_id for this chat
    let row = state
        .db
        .query_one(Statement::from_string(
            DbBackend::Postgres,
            format!("SELECT user_id FROM chats WHERE id = '{}'", chat_id),
        ))
        .await
        .map_err(internal)?
        .ok_or((StatusCode::NOT_FOUND, "chat not found".into()))?;

    let user_id: String = row.try_get_by_index(0).map_err(internal)?;

    // decrement media refs and collect orphaned hashes
    let media_rows = state
        .db
        .query_all(Statement::from_string(
            DbBackend::Postgres,
            format!(
                "SELECT DISTINCT media_hash FROM messages \
                 WHERE chat_id = '{}' AND media_hash IS NOT NULL",
                chat_id
            ),
        ))
        .await
        .map_err(internal)?;

    for row in media_rows {
        let hash: String = row.try_get_by_index(0).map_err(internal)?;

        state
            .db
            .execute(Statement::from_string(
                DbBackend::Postgres,
                format!(
                    "UPDATE media_refs SET ref_count = ref_count - 1 \
                     WHERE hash = '{}' AND user_id = '{}'",
                    hash, user_id
                ),
            ))
            .await
            .map_err(internal)?;

        // remove ref row if count hits 0
        state
            .db
            .execute(Statement::from_string(
                DbBackend::Postgres,
                format!(
                    "DELETE FROM media_refs WHERE hash = '{}' AND user_id = '{}' AND ref_count <= 0",
                    hash, user_id
                ),
            ))
            .await
            .map_err(internal)?;

        // if no refs remain globally, delete from B2
        let ref_count: i64 = state
            .db
            .query_one(Statement::from_string(
                DbBackend::Postgres,
                format!("SELECT COUNT(*) FROM media_refs WHERE hash = '{}'", hash),
            ))
            .await
            .map_err(internal)?
            .map(|r| r.try_get_by_index::<i64>(0).unwrap_or(1))
            .unwrap_or(1);

        if ref_count == 0 {
            let b2_key: Option<String> = state
                .db
                .query_one(Statement::from_string(
                    DbBackend::Postgres,
                    format!("SELECT b2_key FROM media_objects WHERE hash = '{}'", hash),
                ))
                .await
                .map_err(internal)?
                .and_then(|r| r.try_get_by_index(0).ok());

            if let Some(key) = b2_key {
                let _ = state.b2.delete(&key).await;
            }

            state
                .db
                .execute(Statement::from_string(
                    DbBackend::Postgres,
                    format!("DELETE FROM media_objects WHERE hash = '{}'", hash),
                ))
                .await
                .map_err(internal)?;
        }
    }

    // delete chunk files from B2
    let chunks = state
        .db
        .query_all(Statement::from_string(
            DbBackend::Postgres,
            format!("SELECT b2_key FROM b2_chunks WHERE chat_id = '{}'", chat_id),
        ))
        .await
        .map_err(internal)?;

    for row in chunks {
        let key: String = row.try_get_by_index(0).map_err(internal)?;
        let _ = state.b2.delete(&key).await;
    }

    // cascade deletes messages, chunks via FK
    state
        .db
        .execute(Statement::from_string(
            DbBackend::Postgres,
            format!("DELETE FROM chats WHERE id = '{}'", chat_id),
        ))
        .await
        .map_err(internal)?;

    Ok(Json(serde_json::json!({ "deleted": true })))
}

fn brotli_decompress(data: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut out = Vec::new();
    brotli::BrotliDecompress(&mut std::io::Cursor::new(data), &mut out)?;
    Ok(out)
}

fn internal<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
