use serde::{Deserialize, Serialize};
use std::path::Path;
use anyhow::Result;

/// Stub file format written to disk as JSON with `.roamvault` extension.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StubFile {
    pub version: u8,
    pub original_path: String,
    pub b2_key: String,
    pub hash: String,
    pub original_size: u64,
    pub compressed_size: u64,
    pub archived_at: String,
    pub tier: String,
}

impl StubFile {
    /// Reads and parses a `.roamvault` stub from disk.
    pub fn read(path: &Path) -> Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let stub = serde_json::from_str(&content)?;
        Ok(stub)
    }

    /// Returns true if the path looks like a stub file.
    pub fn is_stub(path: &Path) -> bool {
        path.extension().map(|e| e == "roamvault").unwrap_or(false)
    }
}
