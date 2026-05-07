mod archiver;
mod b2;
mod config;
mod restorer;
mod stub;
mod watcher;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::Result;
use slint::ComponentHandle;

use crate::b2::B2Client;
use crate::config::AppConfig;
use crate::watcher::{scan_idle_files, WatchedFolder};

slint::include_modules!();

// Shared application state accessible from both the Slint UI thread and the
// background Tokio runtime.
#[derive(Default)]
struct AppState {
    config: AppConfig,
    total_archived_bytes: u64,
    space_freed_bytes: u64,
    last_sync: Option<chrono::DateTime<chrono::Utc>>,
    archived_files: Vec<stub::StubFile>,
}

fn main() -> Result<()> {
    env_logger::init();

    // Load persisted config.
    let config = AppConfig::load();

    let state = Arc::new(Mutex::new(AppState {
        config: config.clone(),
        ..Default::default()
    }));

    // Build the Slint window.
    let ui = AppWindow::new()?;

    // Populate initial UI state from config.
    {
        let cfg = &config;
        ui.set_b2_key_id(cfg.b2_key_id.clone().into());
        ui.set_b2_app_key(cfg.b2_app_key.clone().into());
        ui.set_b2_bucket(cfg.b2_bucket.clone().into());
        ui.set_default_threshold(cfg.default_threshold_days as i32);

        let folders: Vec<_> = cfg
            .watch_folders
            .iter()
            .map(|f| WatchFolder {
                path: f.path.to_string_lossy().to_string().into(),
                threshold_days: f.threshold_days as i32,
            })
            .collect();
        ui.set_watch_folders(slint::ModelRc::new(slint::VecModel::from(folders)));
        ui.set_archived_files(slint::ModelRc::new(slint::VecModel::from(
            Vec::<ArchivedFile>::new(),
        )));
    }

    // --- Callback: Add watch folder ---
    {
        let state = state.clone();
        let ui_weak = ui.as_weak();
        ui.on_add_watch_folder(move |path, threshold| {
            let path_str = path.to_string();
            if path_str.is_empty() {
                return;
            }
            let mut locked = state.lock().unwrap();
            locked.config.watch_folders.push(WatchedFolder {
                path: PathBuf::from(&path_str),
                threshold_days: threshold as u32,
            });
            let _ = locked.config.save();

            // Refresh UI model.
            let folders: Vec<_> = locked
                .config
                .watch_folders
                .iter()
                .map(|f| WatchFolder {
                    path: f.path.to_string_lossy().to_string().into(),
                    threshold_days: f.threshold_days as i32,
                })
                .collect();
            if let Some(ui) = ui_weak.upgrade() {
                ui.set_watch_folders(slint::ModelRc::new(slint::VecModel::from(folders)));
            }
        });
    }

    // --- Callback: Remove watch folder ---
    {
        let state = state.clone();
        let ui_weak = ui.as_weak();
        ui.on_remove_watch_folder(move |index| {
            let mut locked = state.lock().unwrap();
            let idx = index as usize;
            if idx < locked.config.watch_folders.len() {
                locked.config.watch_folders.remove(idx);
                let _ = locked.config.save();
            }
            let folders: Vec<_> = locked
                .config
                .watch_folders
                .iter()
                .map(|f| WatchFolder {
                    path: f.path.to_string_lossy().to_string().into(),
                    threshold_days: f.threshold_days as i32,
                })
                .collect();
            if let Some(ui) = ui_weak.upgrade() {
                ui.set_watch_folders(slint::ModelRc::new(slint::VecModel::from(folders)));
            }
        });
    }

    // --- Callback: Save settings ---
    {
        let state = state.clone();
        ui.on_save_settings(move |key_id, app_key, bucket, threshold| {
            let mut locked = state.lock().unwrap();
            locked.config.b2_key_id = key_id.to_string();
            locked.config.b2_app_key = app_key.to_string();
            locked.config.b2_bucket = bucket.to_string();
            locked.config.default_threshold_days = threshold as u32;
            let _ = locked.config.save();
            log::info!("Settings saved.");
        });
    }

    // --- Callback: Restore file ---
    {
        let state = state.clone();
        let ui_weak = ui.as_weak();
        ui.on_restore_file(move |index| {
            let (b2_client, stub_path) = {
                let locked = state.lock().unwrap();
                let cfg = &locked.config;
                let client = B2Client::new(
                    cfg.b2_key_id.clone(),
                    cfg.b2_app_key.clone(),
                    cfg.b2_bucket.clone(),
                );
                let file = match locked.archived_files.get(index as usize) {
                    Some(f) => f.clone(),
                    None => return,
                };
                // The stub lives next to the original path.
                let stub_path =
                    archiver::stub_path_for(std::path::Path::new(&file.original_path));
                (client, stub_path)
            };

            tokio::spawn(async move {
                match restorer::restore_file(&b2_client, &stub_path).await {
                    Ok(dest) => log::info!("Restored to {}", dest.display()),
                    Err(e) => log::error!("Restore failed: {e}"),
                }
                // TODO: refresh archived_files list in UI.
            });
        });
    }

    // --- Callback: Run scan now ---
    {
        let state = state.clone();
        let ui_weak = ui.as_weak();
        ui.on_run_scan_now(move || {
            let (folders, b2_client) = {
                let locked = state.lock().unwrap();
                let cfg = &locked.config;
                let client = B2Client::new(
                    cfg.b2_key_id.clone(),
                    cfg.b2_app_key.clone(),
                    cfg.b2_bucket.clone(),
                );
                (locked.config.watch_folders.clone(), client)
            };

            let state2 = state.clone();
            let ui_weak2 = ui_weak.clone();
            tokio::spawn(async move {
                run_archive_cycle(folders, b2_client, state2, ui_weak2.clone()).await;
            });
        });
    }

    // Start Tokio runtime for background work.
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;

    // Spawn the hourly scanner.
    {
        let state = state.clone();
        let ui_weak = ui.as_weak();
        rt.spawn(async move {
            loop {
                let (folders, b2_client) = {
                    let locked = state.lock().unwrap();
                    let cfg = &locked.config;
                    let client = B2Client::new(
                        cfg.b2_key_id.clone(),
                        cfg.b2_app_key.clone(),
                        cfg.b2_bucket.clone(),
                    );
                    (locked.config.watch_folders.clone(), client)
                };
                run_archive_cycle(folders, b2_client, state.clone(), ui_weak.clone()).await;
                tokio::time::sleep(Duration::from_secs(3600)).await;
            }
        });
    }

    // Run the Slint event loop (blocks until the window is closed).
    ui.run()?;

    Ok(())
}

/// One full scan-and-archive pass over all watched folders.
async fn run_archive_cycle(
    folders: Vec<WatchedFolder>,
    b2_client: B2Client,
    state: Arc<Mutex<AppState>>,
    ui_weak: slint::Weak<AppWindow>,
) {
    log::info!("Starting archive cycle over {} folders", folders.len());

    for folder in &folders {
        let idle_files = match scan_idle_files(folder) {
            Ok(f) => f,
            Err(e) => {
                log::error!("Scan error for {}: {e}", folder.path.display());
                continue;
            }
        };

        for idle in idle_files {
            // Only auto-archive files idle >= 60 days.
            if idle.idle_days < 60 {
                log::debug!(
                    "{} idle {}d — below archive threshold",
                    idle.path.display(),
                    idle.idle_days
                );
                continue;
            }

            match archiver::archive_file(&b2_client, &idle.path, idle.idle_days).await {
                Ok(stub) => {
                    let mut locked = state.lock().unwrap();
                    locked.total_archived_bytes += stub.original_size;
                    locked.space_freed_bytes += stub.original_size.saturating_sub(stub.compressed_size);
                    locked.last_sync = Some(chrono::Utc::now());
                    locked.archived_files.push(stub);

                    // Push UI update back to Slint thread.
                    let total_gb = locked.total_archived_bytes as f64 / 1_073_741_824.0;
                    let freed_gb = locked.space_freed_bytes as f64 / 1_073_741_824.0;
                    let last_sync_str = locked
                        .last_sync
                        .map(|t| t.format("%Y-%m-%d %H:%M UTC").to_string())
                        .unwrap_or_else(|| "Never".to_string());
                    let archived: Vec<ArchivedFile> = locked
                        .archived_files
                        .iter()
                        .map(|f| ArchivedFile {
                            original_path: f.original_path.clone().into(),
                            b2_key: f.b2_key.clone().into(),
                            size_mb: f.original_size as f32 / 1_048_576.0,
                            archived_at: f.archived_at.clone().into(),
                            tier: f.tier.clone().into(),
                        })
                        .collect();

                    let _ = ui_weak.upgrade_in_event_loop(move |ui| {
                        ui.set_total_archived_gb(format!("{total_gb:.2}").into());
                        ui.set_space_freed_gb(format!("{freed_gb:.2}").into());
                        ui.set_last_sync_time(last_sync_str.into());
                        ui.set_archived_files(slint::ModelRc::new(slint::VecModel::from(archived)));
                    });
                }
                Err(e) => {
                    log::error!("Archive failed for {}: {e}", idle.path.display());
                }
            }
        }
    }

    log::info!("Archive cycle complete");
}
