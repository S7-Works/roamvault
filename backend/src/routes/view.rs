use crate::AppState;
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::Html,
};
use sea_orm::{ConnectionTrait, Statement, DbBackend};
use std::sync::Arc;

pub async fn serve_viewer(
    State(state): State<Arc<AppState>>,
    Path(uuid): Path<String>,
) -> Result<Html<String>, (StatusCode, String)> {
    let row = state
        .db
        .query_one(Statement::from_string(
            DbBackend::Postgres,
            format!(
                "SELECT id, name, platform, message_count FROM chats WHERE uuid = '{}' LIMIT 1",
                uuid.replace('\'', "''")
            ),
        ))
        .await
        .map_err(internal)?
        .ok_or((StatusCode::NOT_FOUND, "chat not found".into()))?;

    let chat_id: String = row.try_get_by_index::<uuid::Uuid>(0).map_err(internal)?.to_string();
    let chat_name: String = row.try_get_by_index(1).map_err(internal)?;
    let platform: String = row.try_get_by_index(2).map_err(internal)?;
    let message_count: i32 = row.try_get_by_index(3).map_err(internal)?;

    let init_data = serde_json::json!({
        "chatId": chat_id,
        "chatName": chat_name,
        "platform": platform,
        "messageCount": message_count,
    });

    let html = format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>{name} — RoamVault</title>
  <script>window.__INIT__ = {init};</script>
  <script type="module" src="/viewer/assets/index.js"></script>
  <link rel="stylesheet" href="/viewer/assets/index.css" />
</head>
<body>
  <div id="root"></div>
</body>
</html>"#,
        name = chat_name,
        init = init_data,
    );

    Ok(Html(html))
}

fn internal<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
