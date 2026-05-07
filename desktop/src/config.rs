use anyhow::Result;
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::watcher::WatchedFolder;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AppConfig {
    pub b2_key_id: String,
    pub b2_app_key: String,
    pub b2_bucket: String,
    pub default_threshold_days: u32,
    pub watch_folders: Vec<WatchedFolder>,
}

impl AppConfig {
    pub fn config_path() -> Option<PathBuf> {
        ProjectDirs::from("com", "roamvault", "RoamVault").map(|dirs| {
            dirs.config_dir().join("config.json")
        })
    }

    pub fn load() -> Self {
        let path = match Self::config_path() {
            Some(p) => p,
            None => return Self::default(),
        };
        let content = match std::fs::read_to_string(&path) {
            Ok(c) => c,
            Err(_) => return Self::default(),
        };
        serde_json::from_str(&content).unwrap_or_default()
    }

    pub fn save(&self) -> Result<()> {
        let path = Self::config_path()
            .ok_or_else(|| anyhow::anyhow!("cannot determine config path"))?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(&path, json)?;
        Ok(())
    }
}
