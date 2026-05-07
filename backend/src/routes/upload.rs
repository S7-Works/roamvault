use crate::{
    models::UploadResponse,
    parser,
    storage::{brotli_compress, sha256_hex},
    AppState,
};
use axum::{
    extract::{Multipart, State},
    http::StatusCode,
    Json,
};
use chrono::Utc;
use sea_orm::{ConnectionTrait, Statement, DbBackend};
use std::{collections::HashMap, sync::Arc};
use uuid::Uuid;
use zip::ZipArchive;

const CHUNK_SIZE: usize = 1000;

pub async fn whatsapp(
    State(state): State<Arc<AppState>>,
    mut multipart: Multipart,
) -> Result<Json<UploadResponse>, (StatusCode, String)> {
    let mut zip_data: Option<Vec<u8>> = None;
    let mut user_id_str: Option<String> = None;

    while let Some(field) = multipart.next_field().await.map_err(internal)? {
        match field.name() {
            Some("file") => {
                zip_data = Some(field.bytes().await.map_err(internal)?.to_vec());
            }
            Some("user_id") => {
                user_id_str =
                    Some(String::from_utf8(field.bytes().await.map_err(internal)?.to_vec())
                        .map_err(internal)?);
            }
            _ => {}
        }
    }

    let zip_bytes = zip_data.ok_or((StatusCode::BAD_REQUEST, "missing file".into()))?;
    let user_id: Uuid = user_id_str
        .and_then(|s| Uuid::parse_str(&s).ok())
        .unwrap_or_else(Uuid::new_v4);

    // ensure user exists
    state
        .db
        .execute(Statement::from_string(
            DbBackend::Postgres,
            format!(
                "INSERT INTO users (id) VALUES ('{}') ON CONFLICT DO NOTHING",
                user_id
            ),
        ))
        .await
        .map_err(internal)?;

    // unzip in memory
    let cursor = std::io::Cursor::new(&zip_bytes);
    let mut archive = ZipArchive::new(cursor).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let mut chat_text: Option<String> = None;
    let mut media_files: HashMap<String, Vec<u8>> = HashMap::new();

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(internal)?;
        let name = entry.name().to_string();

        if name.ends_with("_chat.txt") || name == "_chat.txt" {
            let mut buf = String::new();
            use std::io::Read;
            entry.read_to_string(&mut buf).map_err(internal)?;
            chat_text = Some(buf);
        } else if !name.ends_with('/') {
            let filename = std::path::Path::new(&name)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(&name)
                .to_string();
            let mut buf = Vec::new();
            use std::io::Read;
            entry.read_to_end(&mut buf).map_err(internal)?;
            media_files.insert(filename, buf);
        }
    }

    let text = chat_text.ok_or((StatusCode::BAD_REQUEST, "no _chat.txt found".into()))?;
    let parsed = parser::parse_chat(&text);
    let message_count = parsed.len();

    let chat_name = detect_chat_name(&text);
    let platform = detect_platform(&text);
    let chat_uuid = Uuid::new_v4().to_string();
    let chat_id = Uuid::new_v4();
    let expires_at = Utc::now() + chrono::Duration::days(7);

    state
        .db
        .execute(Statement::from_string(
            DbBackend::Postgres,
            format!(
                "INSERT INTO chats (id, user_id, uuid, name, platform, message_count, expires_at) \
                 VALUES ('{}', '{}', '{}', '{}', '{}', {}, '{}')",
                chat_id,
                user_id,
                chat_uuid,
                chat_name.replace('\'', "''"),
                platform,
                message_count,
                expires_at.to_rfc3339()
            ),
        ))
        .await
        .map_err(internal)?;

    // upload media files with dedup
    let mut media_hash_map: HashMap<String, String> = HashMap::new();

    for (filename, data) in &media_files {
        let hash = sha256_hex(data);
        let b2_key = format!("media/{}/{}", &hash[..2], hash);
        let content_type = guess_content_type(filename);

        let exists: bool = state
            .db
            .query_one(Statement::from_string(
                DbBackend::Postgres,
                format!("SELECT 1 FROM media_objects WHERE hash = '{}'", hash),
            ))
            .await
            .map_err(internal)?
            .is_some();

        if !exists {
            state
                .b2
                .upload(&b2_key, data.clone(), content_type)
                .await
                .map_err(internal)?;

            state
                .db
                .execute(Statement::from_string(
                    DbBackend::Postgres,
                    format!(
                        "INSERT INTO media_objects (hash, b2_key, size_bytes, content_type) \
                         VALUES ('{}', '{}', {}, '{}')",
                        hash,
                        b2_key,
                        data.len(),
                        content_type
                    ),
                ))
                .await
                .map_err(internal)?;
        }

        state
            .db
            .execute(Statement::from_string(
                DbBackend::Postgres,
                format!(
                    "INSERT INTO media_refs (hash, user_id, ref_count) VALUES ('{}', '{}', 1) \
                     ON CONFLICT (hash, user_id) DO UPDATE SET ref_count = media_refs.ref_count + 1",
                    hash, user_id
                ),
            ))
            .await
            .map_err(internal)?;

        media_hash_map.insert(filename.clone(), hash);
    }

    // insert messages + store chunks
    let chunks: Vec<_> = parsed.chunks(CHUNK_SIZE).enumerate().collect();
    let total_chunks = chunks.len() as i32;

    for (chunk_index, chunk) in parsed.chunks(CHUNK_SIZE).enumerate() {
        let chunk_json: Vec<serde_json::Value> = chunk
            .iter()
            .map(|m| {
                serde_json::json!({
                    "timestamp": m.timestamp,
                    "sender": m.sender,
                    "body": m.body,
                    "media_hash": m.media_filename.as_ref()
                        .and_then(|f| media_hash_map.get(f)),
                })
            })
            .collect();

        let json_bytes = serde_json::to_vec(&chunk_json).map_err(internal)?;
        let compressed = brotli_compress(&json_bytes).map_err(internal)?;
        let chunk_key = format!("chunks/{}/{}", chat_id, chunk_index);

        state
            .b2
            .upload(&chunk_key, compressed, "application/octet-stream")
            .await
            .map_err(internal)?;

        let chunk_id = Uuid::new_v4();
        state
            .db
            .execute(Statement::from_string(
                DbBackend::Postgres,
                format!(
                    "INSERT INTO b2_chunks (id, chat_id, chunk_index, b2_key, message_count) \
                     VALUES ('{}', '{}', {}, '{}', {})",
                    chunk_id,
                    chat_id,
                    chunk_index,
                    chunk_key,
                    chunk.len()
                ),
            ))
            .await
            .map_err(internal)?;

        // insert messages into db for search
        for msg in chunk {
            let media_hash = msg
                .media_filename
                .as_ref()
                .and_then(|f| media_hash_map.get(f))
                .map(|h| format!("'{}'", h))
                .unwrap_or_else(|| "NULL".into());

            let body = msg
                .body
                .as_ref()
                .map(|b| format!("'{}'", b.replace('\'', "''")))
                .unwrap_or_else(|| "NULL".into());

            state
                .db
                .execute(Statement::from_string(
                    DbBackend::Postgres,
                    format!(
                        "INSERT INTO messages (chat_id, timestamp, sender, body, media_hash) \
                         VALUES ('{}', '{}', '{}', {}, {})",
                        chat_id,
                        msg.timestamp.to_rfc3339(),
                        msg.sender.replace('\'', "''"),
                        body,
                        media_hash
                    ),
                ))
                .await
                .map_err(internal)?;
        }
    }

    Ok(Json(UploadResponse {
        view_url: format!("/view/{}", chat_uuid),
        chat_id: chat_id.to_string(),
        message_count,
    }))
}

pub async fn media(
    State(_state): State<Arc<AppState>>,
    mut _multipart: Multipart,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    Ok(Json(serde_json::json!({ "status": "ok" })))
}

fn detect_chat_name(text: &str) -> String {
    text.lines()
        .next()
        .and_then(|l| l.split(" - ").nth(1))
        .and_then(|s| s.split(':').next())
        .unwrap_or("Chat")
        .to_string()
}

fn detect_platform(text: &str) -> &'static str {
    if text.starts_with('[') { "ios" } else { "android" }
}

fn guess_content_type(filename: &str) -> &'static str {
    match filename.rsplit('.').next().unwrap_or("").to_lowercase().as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "ogg" | "opus" => "audio/ogg",
        "aac" => "audio/aac",
        "pdf" => "application/pdf",
        _ => "application/octet-stream",
    }
}

fn internal<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
