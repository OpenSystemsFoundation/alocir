//! Settings and recent folders, kept between launches in the platform's
//! settings folder as small text files (no extra dependencies):
//!
//! - macOS: `~/Library/Application Support/Alocir`
//! - Windows: `%APPDATA%\Alocir`
//! - Linux and others: `$XDG_CONFIG_HOME/alocir` or `~/.config/alocir`
//!
//! Nothing here is required: a missing or unreadable file means defaults.

use alocir_shared::settings::{SettingsState, MAX_NESTING_DEPTH};
use alocir_shared::theme::ColorScheme;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Most recent folders kept.
pub const RECENT_LIMIT: usize = 10;

pub fn config_dir() -> Option<PathBuf> {
    let env = |key: &str| {
        std::env::var_os(key)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    };
    if cfg!(target_os = "macos") {
        Some(env("HOME")?.join("Library/Application Support/Alocir"))
    } else if cfg!(target_os = "windows") {
        Some(env("APPDATA")?.join("Alocir"))
    } else {
        Some(
            env("XDG_CONFIG_HOME")
                .or_else(|| env("HOME").map(|h| h.join(".config")))?
                .join("alocir"),
        )
    }
}

/// What is saved from the settings, and the window size.
#[derive(Clone, Debug, PartialEq)]
pub struct Prefs {
    pub scheme: ColorScheme,
    pub nesting_depth: usize,
    pub show_labels: bool,
    pub show_inspector: bool,
    pub watch_subfolders: bool,
    /// Inner size of the window, in points.
    pub window: Option<[f32; 2]>,
}

impl Prefs {
    pub fn from_settings(settings: &SettingsState, window: Option<[f32; 2]>) -> Prefs {
        Prefs {
            scheme: settings.scheme,
            nesting_depth: settings.nesting_depth,
            show_labels: settings.show_labels,
            show_inspector: settings.show_inspector,
            watch_subfolders: settings.watch_subfolders,
            window,
        }
    }

    pub fn apply_to(&self, settings: &mut SettingsState) {
        settings.scheme = self.scheme;
        settings.nesting_depth = self.nesting_depth;
        settings.show_labels = self.show_labels;
        settings.show_inspector = self.show_inspector;
        settings.watch_subfolders = self.watch_subfolders;
    }

    /// Saved preferences, with defaults for anything missing.
    pub fn load(dir: &Path) -> Prefs {
        let mut prefs = Prefs::from_settings(&SettingsState::new(), None);
        let Ok(text) = std::fs::read_to_string(dir.join("settings.txt")) else {
            return prefs;
        };
        for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let (key, value) = (key.trim(), value.trim());
            let flag = value == "true";
            match key {
                "scheme" => {
                    if let Some(scheme) = ColorScheme::from_name(value) {
                        prefs.scheme = scheme;
                    }
                }
                "nesting_depth" => {
                    if let Ok(depth) = value.parse::<usize>() {
                        prefs.nesting_depth = depth.clamp(1, MAX_NESTING_DEPTH);
                    }
                }
                "show_labels" => prefs.show_labels = flag,
                "show_inspector" => prefs.show_inspector = flag,
                "watch_subfolders" => prefs.watch_subfolders = flag,
                "window" => {
                    let size: Vec<f32> = value.split('x').filter_map(|v| v.parse().ok()).collect();
                    if let [w, h] = size[..] {
                        if w >= 200.0 && h >= 150.0 && w.is_finite() && h.is_finite() {
                            prefs.window = Some([w, h]);
                        }
                    }
                }
                _ => {}
            }
        }
        prefs
    }

    pub fn save(&self, dir: &Path) -> std::io::Result<()> {
        let mut text = format!(
            "scheme = {}\nnesting_depth = {}\nshow_labels = {}\nshow_inspector = {}\nwatch_subfolders = {}\n",
            self.scheme.name(),
            self.nesting_depth,
            self.show_labels,
            self.show_inspector,
            self.watch_subfolders,
        );
        if let Some([w, h]) = self.window {
            text.push_str(&format!("window = {}x{}\n", w.round(), h.round()));
        }
        write_atomically(dir, "settings.txt", &text)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Recent {
    pub path: PathBuf,
    /// Total size at the last scan.
    pub size: u64,
    /// When it was last scanned, in seconds since 1970.
    pub scanned: u64,
}

/// Recently scanned folders, newest first.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Recents {
    pub entries: Vec<Recent>,
}

impl Recents {
    pub fn load(dir: &Path) -> Recents {
        let Ok(text) = std::fs::read_to_string(dir.join("recents.txt")) else {
            return Recents::default();
        };
        let entries = text
            .lines()
            .filter_map(|line| {
                let mut fields = line.splitn(3, '\t');
                let size = fields.next()?.parse().ok()?;
                let scanned = fields.next()?.parse().ok()?;
                let path = fields.next().filter(|p| !p.is_empty())?;
                Some(Recent {
                    path: PathBuf::from(path),
                    size,
                    scanned,
                })
            })
            .take(RECENT_LIMIT)
            .collect();
        Recents { entries }
    }

    pub fn save(&self, dir: &Path) -> std::io::Result<()> {
        let mut text = String::new();
        for entry in &self.entries {
            // One line per folder; a path with a line break can't be stored.
            let Some(path) = entry.path.to_str().filter(|p| !p.contains(['\n', '\r'])) else {
                continue;
            };
            text.push_str(&format!("{}\t{}\t{}\n", entry.size, entry.scanned, path));
        }
        write_atomically(dir, "recents.txt", &text)
    }

    /// Put `path` at the top, with its new size.
    pub fn add(&mut self, path: PathBuf, size: u64) {
        self.entries.retain(|e| e.path != path);
        self.entries.insert(
            0,
            Recent {
                path,
                size,
                scanned: now(),
            },
        );
        self.entries.truncate(RECENT_LIMIT);
    }

    pub fn remove(&mut self, path: &Path) {
        self.entries.retain(|e| e.path != path);
    }
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// "just now", "5 minutes ago", "yesterday", "3 weeks ago", ...
pub fn time_ago(then: u64, now: u64) -> String {
    let seconds = now.saturating_sub(then);
    let plural = |n: u64, unit: &str| {
        if n == 1 {
            format!("1 {unit} ago")
        } else {
            format!("{n} {unit}s ago")
        }
    };
    match seconds {
        0..=59 => "just now".to_string(),
        60..=3_599 => plural(seconds / 60, "minute"),
        3_600..=86_399 => plural(seconds / 3_600, "hour"),
        86_400..=172_799 => "yesterday".to_string(),
        172_800..=1_209_599 => plural(seconds / 86_400, "day"),
        1_209_600..=5_183_999 => plural(seconds / 604_800, "week"),
        5_184_000..=31_535_999 => plural(seconds / 2_592_000, "month"),
        _ => plural(seconds / 31_536_000, "year"),
    }
}

/// Write via a temporary file and rename, so a crash never leaves half a file.
fn write_atomically(dir: &Path, name: &str, text: &str) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{name}.tmp"));
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, dir.join(name))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("alocir-store-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn prefs_round_trip_and_default_when_missing() {
        let dir = temp_dir("prefs");
        assert_eq!(Prefs::load(&dir).nesting_depth, 4);
        let prefs = Prefs {
            scheme: ColorScheme::Phosphor,
            nesting_depth: 6,
            show_labels: false,
            show_inspector: false,
            watch_subfolders: true,
            window: Some([1280.0, 777.0]),
        };
        prefs.save(&dir).unwrap();
        assert_eq!(Prefs::load(&dir), prefs);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn bad_values_fall_back() {
        let dir = temp_dir("bad");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("settings.txt"),
            "scheme = nope\nnesting_depth = 99\nwindow = 10x10\ngarbage\n",
        )
        .unwrap();
        let prefs = Prefs::load(&dir);
        assert!(prefs.scheme == ColorScheme::DarkMode);
        assert_eq!(prefs.nesting_depth, MAX_NESTING_DEPTH);
        assert_eq!(prefs.window, None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn recents_keep_newest_first_without_duplicates() {
        let dir = temp_dir("recents");
        let mut recents = Recents::default();
        for i in 0..12 {
            recents.add(PathBuf::from(format!("/folder {i}")), i);
        }
        recents.add(PathBuf::from("/folder 5"), 500);
        assert_eq!(recents.entries.len(), RECENT_LIMIT);
        assert_eq!(recents.entries[0].path, PathBuf::from("/folder 5"));
        assert_eq!(recents.entries[0].size, 500);
        assert_eq!(
            recents
                .entries
                .iter()
                .filter(|e| e.path == Path::new("/folder 5"))
                .count(),
            1
        );
        recents.save(&dir).unwrap();
        assert_eq!(Recents::load(&dir), recents);
        recents.remove(Path::new("/folder 5"));
        assert_eq!(recents.entries.len(), RECENT_LIMIT - 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn times_read_naturally() {
        assert_eq!(time_ago(100, 130), "just now");
        assert_eq!(time_ago(0, 120), "2 minutes ago");
        assert_eq!(time_ago(0, 90_000), "yesterday");
        assert_eq!(time_ago(0, 15 * 86_400), "2 weeks ago");
    }
}
