use anyhow::Result;
use sea_orm::DatabaseConnection;
use sea_orm::Statement;
use sea_orm::ConnectionTrait;
use sea_orm::DbBackend;

pub async fn run_migrations(db: &DatabaseConnection) -> Result<()> {
    let sql = r#"
        CREATE TABLE IF NOT EXISTS users (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );

        CREATE TABLE IF NOT EXISTS chats (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            uuid VARCHAR NOT NULL UNIQUE,
            name VARCHAR NOT NULL,
            platform VARCHAR NOT NULL,
            message_count INT NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            expires_at TIMESTAMPTZ
        );

        CREATE TABLE IF NOT EXISTS media_objects (
            hash VARCHAR PRIMARY KEY,
            b2_key VARCHAR NOT NULL,
            size_bytes BIGINT NOT NULL,
            content_type VARCHAR NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );

        CREATE TABLE IF NOT EXISTS media_refs (
            hash VARCHAR NOT NULL REFERENCES media_objects(hash),
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            ref_count INT NOT NULL DEFAULT 1,
            PRIMARY KEY (hash, user_id)
        );

        CREATE TABLE IF NOT EXISTS messages (
            id BIGSERIAL PRIMARY KEY,
            chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            timestamp TIMESTAMPTZ NOT NULL,
            sender VARCHAR NOT NULL,
            body TEXT,
            media_hash VARCHAR REFERENCES media_objects(hash),
            search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', COALESCE(body, ''))) STORED
        );

        CREATE INDEX IF NOT EXISTS messages_chat_id_idx ON messages(chat_id);
        CREATE INDEX IF NOT EXISTS messages_search_idx ON messages USING GIN(search_vector);

        CREATE TABLE IF NOT EXISTS b2_chunks (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            chunk_index INT NOT NULL,
            b2_key VARCHAR NOT NULL,
            message_count INT NOT NULL
        );
    "#;

    for stmt in sql.split(';').map(str::trim).filter(|s| !s.is_empty()) {
        db.execute(Statement::from_string(DbBackend::Postgres, stmt.to_string()))
            .await?;
    }

    Ok(())
}
