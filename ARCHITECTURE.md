# RoamVault Architecture

> **Your memories, not your phone's.**  
> Back up everything, browse it anywhere, upgrade your phone without anxiety.

---

## Core Use Case

Phone upgrades should be exciting, not stressful. RoamVault solves the real blocker: years of photos, screenshots, WhatsApp chats, and iMessage/MMS attachments that are too large to move, too scattered to manage, and too important to delete. RoamVault gets everything off your device and into cheap, durable cloud storage — so your next phone starts fresh and your memories stay intact.

---

## Components

```
┌─────────────────────────────────────────────────────┐
│                  Flutter Mobile App                  │
│         iOS + Android — the primary interface        │
│  Camera roll · Screenshots · WhatsApp · App cleanup  │
├─────────────────────────────────────────────────────┤
│           Native iOS Extensions (Swift)              │
│  FileProvider · Photos Library · Background sync    │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│              Rust + Axum Backend API                 │
│   Upload · Parse · Dedup · Auth · Serve viewer       │
└────────┬───────────────────────┬────────────────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐   ┌──────────────────────────────┐
│   PostgreSQL     │   │        Backblaze B2           │
│  (SeaORM)        │   │  Media + Brotli chat chunks  │
│  Metadata · Auth │   │  Global dedup via SHA-256    │
│  Message index   │   └──────────────────────────────┘
└─────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│           WhatsApp Viewer (SolidJS)                  │
│   Web — shareable link, chat bubble UI, inline media │
│   serde_json hydration → FlatBuffers for data loads  │
└─────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Choice |
|---|---|
| Mobile app | Flutter (iOS + Android) |
| iOS native extensions | Swift (FileProvider, Photos Library) |
| Backend | Rust + Axum |
| ORM | SeaORM + PostgreSQL |
| Serialization | serde_json (initial hydration) → FlatBuffers (data transport) |
| Web frontend | SolidJS |
| Object storage | Backblaze B2 (S3-compatible) |
| Compression | Brotli (chat text + JSON chunks) |
| Dedup | Global SHA-256, per-user reference counting |
| Deployment | Railway |

---

## iOS Native Extensions (Swift)

RoamVault ships as a Flutter app with native Swift app extensions to unlock deep iOS integration unavailable to Flutter alone.

### FileProvider Extension
Registers RoamVault as an **official storage provider** in the iOS Files app alongside iCloud Drive, Dropbox, and Google Drive.

```
Settings > [Your Name] > iCloud           (Apple)
Files app > Browse > Locations            (third-party)
  └── RoamVault  ← appears here automatically
```

**What this enables:**
- Users browse and restore backed-up files directly from Files app
- Any app that supports "Open from..." can access RoamVault storage
- iOS can offload content directly to RoamVault as a storage destination
- Works with iOS Shortcuts for automated backup workflows

**Implementation:**
```
RoamVaultApp.xcodeproj
├── RoamVaultFileProvider/          # FileProvider extension target
│   ├── FileProviderExtension.swift # NSFileProviderExtension subclass
│   ├── FileProviderItem.swift      # NSFileProviderItem — maps B2 objects
│   └── FileProviderEnumerator.swift # Lists files/folders from B2
└── RoamVaultApp/                   # Main Flutter host app
```

The FileProvider extension communicates with B2 via the same Rust backend API — it fetches directory listings and downloads files on demand (no full sync required).

### Photos Library Extension
Registers RoamVault as a storage location in the **Photos app**:
- Users can select RoamVault as an album export destination
- Enables direct camera offload workflow inside Photos
- Appears under Photos > Albums > Shared Albums (as a provider)

### Background Sync (BGTaskScheduler)
Swift background task runs even when Flutter app is closed:
- `BGProcessingTask` — full backup sync when on WiFi + charging
- `BGAppRefreshTask` — lightweight check for new photos every few hours
- Hands off actual upload work to the Rust backend via HTTP

### App Store Requirements
- FileProvider extension requires App Store distribution (no TestFlight-only)
- Apple review specifically checks: user data privacy, encryption in transit, deletion capability
- All B2 transfers must use HTTPS (already satisfied)
- User must be able to delete all their data from within the app (build this explicitly)

---

## Flutter Mobile App

### iOS Capabilities
| Feature | Approach |
|---|---|
| Camera roll + screenshots | `photo_manager` plugin |
| WhatsApp backup | User exports `.zip` manually → app picks it up |
| iMessage attachments | Deep link to Settings (sandboxed, no direct access) |
| App storage analysis | `device_info_plus` + Settings deep link |
| Files app integration | Native FileProvider extension (Swift) |
| Photos app integration | Native Photos Library extension (Swift) |
| Background sync | Native BGTaskScheduler (Swift) |

### Android Capabilities
| Feature | Approach |
|---|---|
| Camera roll + screenshots | `photo_manager` plugin |
| WhatsApp backup | Direct file access at `/sdcard/WhatsApp/` |
| MMS attachments | `content://mms/` content provider |
| App storage analysis | `android_package_manager` — full per-app storage stats |

### App Screens
1. **Dashboard** — storage overview, backup status, last sync
2. **Backup** — select what to back up (camera roll, screenshots, WhatsApp, MMS)
3. **App Analysis** — per-app storage usage, last-used, deletion recommendations
4. **Viewer** — opens WhatsApp viewer web link in-app
5. **Settings** — B2 credentials, backup schedule, expiry preferences

---

## Backend: Rust + Axum

### API Routes
```
POST   /upload/whatsapp       # Upload WhatsApp .zip
POST   /upload/media          # Upload photos/screenshots from Flutter
GET    /view/:id              # Serve chat viewer page
GET    /api/chat/:id/messages # Paginated messages (FlatBuffers)
GET    /api/media/:hash       # Serve media via B2 signed URL
DELETE /chat/:id              # Delete chat + decrement refs
GET    /api/storage/stats     # User's storage usage summary
```

### Chat Processing Pipeline
```
Upload .zip
      ↓
Unzip → extract _chat.txt + media files
      ↓
SHA-256 hash each media file → dedup check
      ↓
Parse _chat.txt (handles both iOS and Android formats)
      ↓
Store messages in PostgreSQL (metadata + search index)
      ↓
Serialize message chunks → Brotli compress → store in B2
      ↓
Return /view/:uuid to client
```

### Message Parser
Handles both export formats:
```
# Android
12/31/2024, 10:30 AM - John: Hey!

# iPhone
[12/31/2024, 10:30:00 AM] John: Hey!
```

Parsed into:
```rust
struct Message {
    timestamp: DateTime<Utc>,
    sender: String,
    body: Option<String>,
    media_hash: Option<String>,
}
```

---

## Storage: Backblaze B2

### Dedup Strategy (Global, Per-User Refs)
```
media_objects:  { hash, b2_key, size_bytes }
media_refs:     { hash, user_id, ref_count }
messages:       { ..., media_hash }
```

**Upload flow:**
```
Hash file (SHA-256)
      ↓
Does hash exist in media_objects?
  YES → increment media_refs.ref_count for this user
  NO  → upload to B2, insert media_objects row, create media_refs row
```

**Delete flow:**
```
User deletes chat
      ↓
Decrement media_refs.ref_count for their user_id
      ↓
ref_count = 0 → remove media_refs row
      ↓
No media_refs rows for this hash → delete from B2 + media_objects
```

### Compression
| Content type | Strategy |
|---|---|
| JPEG / PNG / WEBP | Store raw (already compressed) |
| MP4 / video | Store raw |
| OGG / audio | Store raw |
| Chat message JSON chunks | Brotli compress before storing in B2 |
| FlatBuffers payloads | Served with `Content-Encoding: br` |

Chat messages are chunked (1000 messages per chunk) for lazy loading as user scrolls.

---

## Web Viewer: SolidJS

### Data Loading Strategy
```
Initial page load
      ↓
serde_json payload hydrates SolidJS signals (chat metadata, first chunk)
      ↓
User scrolls → fetch next chunk via FlatBuffers API
      ↓
SolidJS deserializes FlatBuffers directly, zero-copy
```

### Features
- Chat bubble UI (sender-colored, timestamps)
- Inline images and videos
- Lazy-load media via signed B2 URLs
- Full-text search (backed by PostgreSQL tsvector)
- Shareable link (`/view/:uuid`) — unguessable, no login required
- Auto-expiry (configurable, default 7 days)
- Optional: password protection (Phase 2)

---

## PostgreSQL Schema (SeaORM)

```sql
users          (id, created_at)
chats          (id, user_id, uuid, name, platform, message_count, created_at, expires_at)
messages       (id, chat_id, timestamp, sender, body, media_hash)
media_objects  (hash, b2_key, size_bytes, content_type, created_at)
media_refs     (hash, user_id, ref_count)
b2_chunks      (id, chat_id, chunk_index, b2_key, message_count)
```

Full-text search index on `messages.body` via `tsvector`.

---

## FlatBuffers Schema

```fbs
table Message {
  timestamp: int64;
  sender: string;
  body: string;
  media_url: string;
}

table MessageChunk {
  messages: [Message];
  chunk_index: int32;
  total_chunks: int32;
}
```

---

## Deployment: Railway

| Service | Railway resource |
|---|---|
| Rust API | Railway service (Dockerfile) |
| PostgreSQL | Railway managed Postgres |
| SolidJS viewer | Railway static site or separate service |
| B2 storage | External (Backblaze) |

Environment variables managed via Railway — B2 key ID, app key, bucket name, DB URL.

---

## Build Phases

### Phase 1 — WhatsApp Viewer (Web)
- Rust backend: upload, parse, store, serve
- SolidJS viewer: chat UI, lazy load, search
- B2 integration: upload, dedup, signed URLs
- Shareable links + auto-expiry

### Phase 2 — Flutter App (Backup)
- Camera roll + screenshot backup to B2
- Android: WhatsApp direct backup, MMS export
- iOS: WhatsApp zip import, Settings deep links
- Dashboard with storage stats

### Phase 3 — App Analysis + Cleanup
- Android: per-app storage analysis, deletion recommendations
- iOS: storage overview, deep links to reclaim space
- Pre-upgrade checklist: "safe to wipe" confirmation flow

### Phase 4 — iOS Deep Integration (Swift Extensions)
- FileProvider extension: RoamVault appears in Files app as storage provider
- Photos Library extension: direct camera offload from Photos app
- BGTaskScheduler: background sync on WiFi + charging
- App Store submission with FileProvider entitlements

### Phase 5 — Polish
- Password-protected chat links
- Multiple chats per account
- Restore flow for new phone setup — "start fresh" checklist before upgrade
- Pre-upgrade readiness score: "X GB backed up, safe to wipe"
