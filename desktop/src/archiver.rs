use anyhow::{Context, Result};
use chrono::Utc;
use std::path::{Path, PathBuf};

use crate::b2::{self, B2Client};
use crate::stub::StubFile;

/// Determines tier based on idle_days.
fn tier_for_days(idle_days: u64) -> &'static str {
    if idle_days >= 90 {
        "deep_archive"
    } else {
        "standard"
    }
}

/// Archives a single file:
/// 1. Reads raw bytes, computes SHA-256.
/// 2. Brotli-compresses the data.
/// 3. Uploads to B2 under `archives/<hex_prefix>/<filename>.br`.
/// 4. Writes a `.roamvault` stub replacing the original file.
pub async fn archive_file(client: &B2Client, path: &Path, idle_days: u64) -> Result<StubFile> {
    let raw = std::fs::read(path)
        .with_context(|| format!("reading {}", path.display()))?;

    let original_size = raw.len() as u64;
    let hash = b2::sha256_hex(&raw);

    let compressed = b2::brotli_compress(&raw)
        .with_context(|| "brotli compression failed")?;
    let compressed_size = compressed.len() as u64;

    // Build a deterministic B2 key: archives/<first8 of hash>/<filename>.br
    let filename = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    let b2_key = format!("archives/{}/{}.br", &hash[..8], filename);

    client
        .upload(&b2_key, compressed, "application/x-brotli")
        .await
        .with_context(|| format!("uploading {} to B2", path.display()))?;

    let stub = StubFile {
        version: 1,
        original_path: path.to_string_lossy().to_string(),
        b2_key: b2_key.clone(),
        hash,
        original_size,
        compressed_size,
        archived_at: Utc::now().to_rfc3339(),
        tier: tier_for_days(idle_days).to_string(),
    };

    // Write stub and delete original.
    let stub_path = stub_path_for(path);
    let stub_json = serde_json::to_string_pretty(&stub)?;
    std::fs::write(&stub_path, stub_json)
        .with_context(|| format!("writing stub {}", stub_path.display()))?;
    std::fs::remove_file(path)
        .with_context(|| format!("removing original {}", path.display()))?;

    log::info!(
        "Archived {} -> {} ({}B -> {}B, tier={})",
        path.display(),
        b2_key,
        original_size,
        compressed_size,
        stub.tier
    );

    Ok(stub)
}

/// Returns the stub path for an original file path.
pub fn stub_path_for(original: &Path) -> PathBuf {
    let mut p = original.to_path_buf();
    let ext = match original.extension() {
        Some(e) => format!("{}.roamvault", e.to_string_lossy()),
        None => "roamvault".to_string(),
    };
    p.set_extension(ext);
    p
}
