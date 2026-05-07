use anyhow::Result;
use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
use tokio::sync::mpsc;

/// A watched folder configuration.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WatchedFolder {
    pub path: PathBuf,
    /// Days of inactivity before archiving.
    pub threshold_days: u32,
}

/// Result of idle detection for a single file.
#[derive(Debug, Clone)]
pub struct IdleFile {
    pub path: PathBuf,
    pub idle_days: u64,
    pub size: u64,
}

/// Scans a watched folder and returns files that have been idle >= threshold_days.
pub fn scan_idle_files(folder: &WatchedFolder) -> Result<Vec<IdleFile>> {
    let threshold_secs = folder.threshold_days as u64 * 86_400;
    let now = SystemTime::now();
    let mut idle = Vec::new();

    visit_dir(&folder.path, &mut |path: &Path| {
        // Skip .roamvault stub files — they are placeholders.
        if path.extension().map(|e| e == "roamvault").unwrap_or(false) {
            return;
        }

        let meta = match std::fs::metadata(path) {
            Ok(m) => m,
            Err(_) => return,
        };

        if !meta.is_file() {
            return;
        }

        // Use modified time as the "last touched" proxy (accessed time is unreliable on macOS).
        let last_modified = match meta.modified() {
            Ok(t) => t,
            Err(_) => return,
        };

        let idle_secs = match now.duration_since(last_modified) {
            Ok(d) => d.as_secs(),
            Err(_) => return,
        };

        if idle_secs >= threshold_secs {
            idle.push(IdleFile {
                path: path.to_owned(),
                idle_days: idle_secs / 86_400,
                size: meta.len(),
            });
        }
    });

    Ok(idle)
}

fn visit_dir(dir: &Path, cb: &mut dyn FnMut(&Path)) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            visit_dir(&path, cb);
        } else {
            cb(&path);
        }
    }
}

/// Starts a background notify watcher that sends changed paths over a channel.
/// Returns (watcher handle to keep alive, receiver channel).
pub fn start_fs_watcher(
    folders: Vec<PathBuf>,
) -> Result<(RecommendedWatcher, mpsc::Receiver<PathBuf>)> {
    let (tx, rx) = mpsc::channel::<PathBuf>(256);

    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| {
            if let Ok(event) = res {
                for path in event.paths {
                    let _ = tx.blocking_send(path);
                }
            }
        },
        Config::default().with_poll_interval(Duration::from_secs(60)),
    )?;

    for folder in &folders {
        watcher.watch(folder, RecursiveMode::Recursive)?;
    }

    Ok((watcher, rx))
}
