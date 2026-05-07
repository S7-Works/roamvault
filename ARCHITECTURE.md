# RoamVault Architecture

> **Your memories, not your phone's.**  
> Back up everything, browse it anywhere, upgrade your phone without anxiety.

---

## Core Use Case

Phone upgrades should be exciting, not stressful. RoamVault solves the real blocker: years of photos, screenshots, WhatsApp chats, and iMessage/MMS attachments that are too large to move, too scattered to manage, and too important to delete. RoamVault gets everything off your device and into cheap, durable cloud storage — so your next phone starts fresh and your memories stay intact.

The desktop agent extends this to your computer: folders and files are automatically archived to B2 based on inactivity, replaced with placeholder links that restore on demand — just like iCloud optimized storage, but for everything.

---

## Components

```
┌──────────────────────────┐   ┌──────────────────────────────┐
│   Desktop Agent (Slint)  │   │     Mobile App (Slint UI)    │
│   Mac · Win · Linux      │   │   Flutter shell · iOS/Android│
│   Menubar/tray daemon    │   │   Slint renders the UI       │
│   Virtual FS placeholders│   ├──────────────────────────────┤
│   30/60/90d idle archive │   │  Native iOS Extensions (Swift)│
│   ADB phone app backup   │   │  FileProvider · BGTaskScheduler│
└────────────┬─────────────┘   └──────────────┬───────────────┘
             │                                 │
             └──────────────┬──────────────────┘
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
│  File index      │   │  Brotli-compressed archives  │
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
| Desktop UI | **Slint** (Mac / Windows / Linux) |
| Mobile UI | **Slint** (rendered inside Flutter shell) |
| Mobile OS hooks | Flutter (photo_manager, ADB bridge, deep links) |
| iOS native extensions | Swift (FileProvider, Photos Library, BGTaskScheduler) |
| Backend | Rust + Axum |
| ORM | SeaORM + PostgreSQL |
| Serialization | serde_json (initial hydration) → FlatBuffers (data transport) |
| Web frontend | SolidJS |
| Object storage | Backblaze B2 (S3-compatible) |
| Compression | Brotli (archives, chat chunks, JSON payloads) |
| Dedup | Global SHA-256, per-user reference counting |
| Deployment | Railway |

---

## Desktop Agent (Slint + Rust)

Runs as a background menubar/tray daemon on Mac, Windows, and Linux. Watches your filesystem, archives idle content to B2, and replaces files with lightweight placeholders that restore on demand.

### Idle-Based Archiving

Files and folders are archived based on last-accessed time:

| Threshold | Action |
|---|---|
| 30 days untouched | Flag for archiving — shown in Slint UI as "ready to archive" |
| 60 days untouched | Auto-archive: Brotli compress → upload to B2 → replace with placeholder |
| 90 days untouched | Deep archive: same as 60d but marked low-priority in B2 lifecycle |

Users can override thresholds per folder, or manually trigger archive/restore at any time.

### Placeholder Files (Virtual Filesystem)

After archiving, the original file/folder is replaced with a stub. Clicking the stub triggers a restore dialog (via the OS shell extension), downloads from B2, and replaces the stub with the real content.

| OS | Virtual FS Mechanism |
|---|---|
| macOS | **FileProvider** (macOS 12+ — same API as iOS) |
| Windows | **Cloud Files API** (same mechanism as OneDrive) |
| Linux | **FUSE** + custom xattr metadata for stub marker |

Stub files are tiny (< 1KB) and contain the B2 object key + metadata needed to restore.

### Archive Pipeline
```
Idle threshold hit (or manual trigger)
      ↓
Read file/folder from disk
      ↓
SHA-256 hash → dedup check against PostgreSQL
      ↓
Brotli compress (folders bundled as .tar before compress)
      ↓
Upload to B2 → store object key + hash in PostgreSQL
      ↓
Replace file/folder with placeholder stub
      ↓
OS shows stub with RoamVault overlay icon
```

### Restore Pipeline
```
User clicks placeholder stub
      ↓
OS shell extension intercepts → triggers restore dialog (Slint)
      ↓
User confirms → download from B2
      ↓
Brotli decompress → write to original path
      ↓
Remove stub → file available normally
```

### Phone App Backup via ADB (Android)

When an Android phone is connected via USB or on the same WiFi network:

```
Detect device (ADB over USB or ADB over TCP/IP)
      ↓
List installed packages + APKs
      ↓
adb pull APKs → Brotli compress → upload to B2
      ↓
adb backup app data (where permitted) → upload to B2
      ↓
Indexed in PostgreSQL with device ID + app package name
```

Restore: push APK + data back to new device via ADB.

### Slint UI Screens (Desktop)
1. **Overview** — total archived, storage saved, last sync
2. **File Browser** — see all archived files/folders, restore any
3. **Watch Folders** — configure which paths to monitor + thresholds
4. **Phone** — connected Android devices, app backup status
5. **Settings** — B2 credentials, thresholds, compression level

---

## iOS: Official Storage Provider Roadmap

The goal is for RoamVault to appear as a first-class storage destination on iOS — alongside iCloud — in Settings, Files, and Photos.

### What's Available Today (FileProvider)

```
Files app > Browse > Locations
  ├── iCloud Drive
  ├── On My iPhone
  └── RoamVault  ← FileProvider extension
```

Any app that uses UIDocumentPickerViewController (nearly all iOS apps) will offer RoamVault as a storage location automatically.

### Native Swift Extensions

**FileProvider Extension**
```
RoamVaultApp.xcodeproj
├── RoamVaultFileProvider/
│   ├── FileProviderExtension.swift   # NSFileProviderExtension subclass
│   ├── FileProviderItem.swift        # Maps B2 objects to iOS file items
│   └── FileProviderEnumerator.swift  # Lists files/folders from B2
└── RoamVaultApp/                     # Flutter host app
```

Supports placeholder items — files show as available in Files app but are only downloaded when opened (identical UX to iCloud optimized storage).

**Photos Library Extension**
- RoamVault appears as an album destination in Photos app
- Direct camera offload: photos move to B2, placeholder thumbnail stays in Photos
- Users can browse full-res photos in RoamVault without them taking local storage

**Background Sync (BGTaskScheduler)**
- `BGProcessingTask` — full sync on WiFi + charging
- `BGAppRefreshTask` — lightweight new-photo check every few hours
- Delegates upload work to Rust backend via HTTP

**iOS App Backup (Sandboxed)**
- Documents folder: accessible via FileProvider, backed up to B2
- Photos/videos: via PhotoKit, backed up to B2
- App data beyond documents: not accessible (Apple sandbox)

### Path to Full iCloud Backup Alternative

| Step | How |
|---|---|
| 1. Ship FileProvider on App Store | Available to any developer today |
| 2. Build user base + reliability track record | Organic growth |
| 3. Apply for Alternative Cloud Backup entitlement | Apple developer partnership program |
| 4. Appear in `Settings > [Name] > iCloud > Backup Destination` | Requires Apple approval |
| 5. Full device backup destination (like Google One) | Enterprise/partnership tier |

Steps 1-2 are in our control. Steps 3-5 require Apple approval — Dropbox and Google One have these entitlements today.

**App Store Requirements for FileProvider:**
- App Store distribution required (no TestFlight-only)
- All transfers encrypted (HTTPS — already satisfied)
- User must be able to delete all data from within the app
- Apple review scrutinizes storage providers carefully — privacy policy must be explicit

---

## Mobile App (Slint UI + Flutter Shell)

Flutter provides the OS-level hooks (photo_manager, platform channels to Swift extensions, ADB bridge). Slint renders all UI.

### iOS Capabilities
| Feature | Approach |
|---|---|
| Camera roll + screenshots | `photo_manager` plugin |
| WhatsApp backup | User exports `.zip` → app picks it up |
| iMessage attachments | Settings deep link (sandboxed) |
| Files app integration | Native FileProvider extension (Swift) |
| Photos app integration | Native Photos Library extension (Swift) |
| Background sync | BGTaskScheduler (Swift) |
| App data backup | Documents + photos only (sandbox limit) |

### Android Capabilities
| Feature | Approach |
|---|---|
| Camera roll + screenshots | `photo_manager` plugin |
| WhatsApp backup | Direct file access `/sdcard/WhatsApp/` |
| MMS attachments | `content://mms/` content provider |
| App storage analysis | `android_package_manager` |
| App backup | ADB over USB or WiFi from desktop agent |

### App Screens (Slint)
1. **Dashboard** — storage overview, backup status, last sync, space freed
2. **Backup** — camera roll, screenshots, WhatsApp, MMS
3. **App Analysis** — per-app storage, last-used, deletion recommendations
4. **Viewer** — WhatsApp chat viewer (in-app webview)
5. **Settings** — B2 credentials, thresholds, background sync

---

## Backend: Rust + Axum

### API Routes
```
POST   /upload/whatsapp         # Upload WhatsApp .zip
POST   /upload/media            # Upload photos/screenshots
POST   /upload/archive          # Upload Brotli-compressed desktop archive
POST   /upload/apk              # Upload Android APK + app data
GET    /view/:id                # Serve WhatsApp viewer page
GET    /api/chat/:id/messages   # Paginated messages (FlatBuffers)
GET    /api/media/:hash         # Serve media via B2 signed URL
GET    /api/files               # List archived files/folders for user
GET    /api/files/:id/restore   # Get signed B2 URL for restore download
DELETE /chat/:id                # Delete chat + decrement refs
DELETE /files/:id               # Delete archive + decrement refs
GET    /api/storage/stats       # User storage summary
```

### Chat Processing Pipeline
```
Upload .zip
      ↓
Unzip → extract _chat.txt + media files
      ↓
SHA-256 hash each media file → dedup check
      ↓
Parse _chat.txt (iOS and Android formats)
      ↓
Store messages in PostgreSQL (metadata + tsvector search index)
      ↓
Serialize message chunks → Brotli compress → store in B2
      ↓
Return /view/:uuid to client
```

### Message Parser
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
media_objects:  { hash, b2_key, size_bytes, content_type }
media_refs:     { hash, user_id, ref_count }
messages:       { ..., media_hash }
archived_files: { ..., content_hash }
```

**Upload flow:**
```
SHA-256 hash file/archive
      ↓
Hash exists in media_objects?
  YES → increment media_refs.ref_count for user
  NO  → upload to B2 → insert media_objects + media_refs
```

**Delete flow:**
```
User deletes item
      ↓
Decrement media_refs.ref_count
      ↓
ref_count = 0 → remove media_refs row
      ↓
No refs remain → delete from B2 + media_objects
```

### Compression
| Content type | Strategy |
|---|---|
| JPEG / PNG / WEBP / MP4 | Store raw (already compressed) |
| Folders / text files / documents | `.tar` → Brotli compress → B2 |
| APKs | Store raw (already compressed zip) |
| App data | Brotli compress → B2 |
| Chat message JSON chunks | Brotli compress → B2 |
| FlatBuffers API responses | `Content-Encoding: br` |

---

## Web Viewer: SolidJS

### Data Loading
```
Initial page load → serde_json hydrates SolidJS signals
      ↓
Scroll → fetch next chunk via FlatBuffers API
      ↓
SolidJS deserializes FlatBuffers zero-copy
```

### Features
- Chat bubble UI, sender colors, timestamps
- Inline images + videos via signed B2 URLs
- Full-text search (PostgreSQL tsvector)
- Shareable `/view/:uuid` link, auto-expiry (default 7 days)
- Password protection (Phase 2)

---

## PostgreSQL Schema (SeaORM)

```sql
users           (id, created_at)
chats           (id, user_id, uuid, name, platform, message_count, created_at, expires_at)
messages        (id, chat_id, timestamp, sender, body, media_hash, search_vector tsvector)
media_objects   (hash, b2_key, size_bytes, content_type, created_at)
media_refs      (hash, user_id, ref_count)
b2_chunks       (id, chat_id, chunk_index, b2_key, message_count)
archived_files  (id, user_id, original_path, content_hash, b2_key, compressed_size,
                 original_size, archived_at, last_accessed, archive_tier)
apk_backups     (id, user_id, device_id, package_name, version, b2_key, backed_up_at)
devices         (id, user_id, platform, device_name, last_seen)
```

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

table ArchivedFile {
  id: string;
  original_path: string;
  size_bytes: int64;
  archived_at: int64;
  tier: int8;
}

table FileList {
  files: [ArchivedFile];
  total_count: int32;
}
```

---

## Deployment: Railway

| Service | Railway resource |
|---|---|
| Rust API | Railway service (Dockerfile) |
| PostgreSQL | Railway managed Postgres |
| SolidJS viewer | Railway static site |
| B2 storage | External (Backblaze) |

---

## Build Phases

### Phase 1 — WhatsApp Viewer (Web)
- Rust backend: upload, parse, store, serve
- SolidJS viewer: chat UI, lazy load, search
- B2 integration: dedup, signed URLs, Brotli chunks
- Shareable links + auto-expiry

### Phase 2 — Desktop Agent (Slint)
- Rust daemon: filesystem watcher, idle detection
- 30/60/90 day archive thresholds
- Brotli compress + upload to B2
- Placeholder stubs + restore dialog
- macOS FileProvider + Windows Cloud Files API + Linux FUSE
- Slint UI: overview, file browser, watch folders, settings

### Phase 3 — Mobile App (Slint + Flutter)
- Camera roll + screenshot backup
- Android: WhatsApp direct, MMS export
- iOS: WhatsApp zip import, Settings deep links
- Slint UI: dashboard, backup, app analysis

### Phase 4 — Android App Backup (ADB)
- ADB detection over USB + WiFi
- APK pull + Brotli compress → B2
- App data backup where permitted
- Restore to new device flow

### Phase 5 — iOS Deep Integration (Swift Extensions)
- FileProvider: RoamVault in Files app with placeholder support
- Photos Library extension: camera offload
- BGTaskScheduler: background sync
- App Store submission with FileProvider entitlements
- iOS app data backup (documents + photos)

### Phase 6 — Apple Storage Provider Partnership
- Establish App Store presence + user base
- Apply for Alternative Cloud Backup entitlement
- Appear in `Settings > [Name] > iCloud > Backup Destination`
- Full device backup destination parity with iCloud/Google One

### Phase 7 — Polish
- Password-protected chat links
- Pre-upgrade readiness score: "X GB backed up, safe to wipe"
- Restore flow: one-tap new phone setup from RoamVault
- Cross-device dedup report: "You saved X GB across Y devices"
