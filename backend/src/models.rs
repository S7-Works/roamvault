use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Serialize, Deserialize)]
pub struct Chat {
    pub id: Uuid,
    pub user_id: Uuid,
    pub uuid: String,
    pub name: String,
    pub platform: String,
    pub message_count: i32,
    pub created_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Message {
    pub id: i64,
    pub chat_id: Uuid,
    pub timestamp: DateTime<Utc>,
    pub sender: String,
    pub body: Option<String>,
    pub media_hash: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MessageChunk {
    pub messages: Vec<MessageView>,
    pub chunk_index: i32,
    pub total_chunks: i32,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct MessageView {
    pub timestamp: DateTime<Utc>,
    pub sender: String,
    pub body: Option<String>,
    pub media_url: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MediaObject {
    pub hash: String,
    pub b2_key: String,
    pub size_bytes: i64,
    pub content_type: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct StorageStats {
    pub total_chats: i64,
    pub total_messages: i64,
    pub total_media_bytes: i64,
    pub unique_media_objects: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UploadResponse {
    pub view_url: String,
    pub chat_id: String,
    pub message_count: usize,
}
