use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

use crate::b2::{self, B2Client};
use crate::stub::StubFile;

/// Restores a file from a stub:
/// 1. Parses the `.roamvault` stub.
/// 2. Downloads compressed bytes from B2.
/// 3. Brotli-decompresses.
/// 4. Verifies SHA-256 hash.
/// 5. Writes file to `original_path`, removes stub.
pub async fn restore_file(client: &B2Client, stub_path: &Path) -> Result<PathBuf> {
    let stub = StubFile::read(stub_path)
        .with_context(|| format!("parsing stub {}", stub_path.display()))?;

    let compressed = client
        .download(&stub.b2_key)
        .await
        .with_context(|| format!("downloading {} from B2", stub.b2_key))?;

    let raw = b2::brotli_decompress(&compressed)
        .with_context(|| "brotli decompression failed")?;

    // Verify integrity.
    let actual_hash = b2::sha256_hex(&raw);
    if actual_hash != stub.hash {
        anyhow::bail!(
            "Hash mismatch for {}: expected {}, got {}",
            stub.original_path,
            stub.hash,
            actual_hash
        );
    }

    let dest = PathBuf::from(&stub.original_path);

    // Ensure parent directory exists.
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating directory {}", parent.display()))?;
    }

    std::fs::write(&dest, &raw)
        .with_context(|| format!("writing restored file {}", dest.display()))?;

    std::fs::remove_file(stub_path)
        .with_context(|| format!("removing stub {}", stub_path.display()))?;

    log::info!("Restored {} from B2 key {}", dest.display(), stub.b2_key);

    Ok(dest)
}

/// Finds all stub files recursively under a directory.
pub fn find_stubs(dir: &Path) -> Vec<PathBuf> {
    let mut stubs = Vec::new();
    visit_for_stubs(dir, &mut stubs);
    stubs
}

fn visit_for_stubs(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            visit_for_stubs(&path, out);
        } else if StubFile::is_stub(&path) {
            out.push(path);
        }
    }
}
