use crate::kind::FileKind;
use rayon::prelude::*;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub struct FileNode {
    pub name: String,
    pub size: u64,
    pub children: Vec<FileNode>,
    pub is_dir: bool,
    /// What the file is, from its extension (`Directory` for directories).
    /// Fits in the padding after `is_dir`, so it costs no memory.
    pub kind: FileKind,
    /// Search marks (see [`crate::search::MATCH`]), so painting can dim
    /// what doesn't match without a lookup.
    pub mark: u8,
}

impl FileNode {
    pub fn new(name: String, size: u64, children: Vec<FileNode>, is_dir: bool) -> FileNode {
        let kind = if is_dir {
            FileKind::Directory
        } else {
            FileKind::from_name(&name)
        };
        FileNode {
            name,
            size,
            children,
            is_dir,
            kind,
            mark: 0,
        }
    }
}

pub struct ScanProgress {
    pub items_scanned: AtomicU64,
    pub bytes_scanned: AtomicU64,
    pub current_path: Mutex<String>,
    pub done: Mutex<bool>,
    pub result: Mutex<Option<FileNode>>,
    pub duration: Mutex<Option<Duration>>,
    /// When the scan started; used to throttle `current_path` updates.
    started: Instant,
    /// Milliseconds after `started` of the last `current_path` update.
    last_path_update_ms: AtomicU64,
    /// Hard-linked files already counted in this scan.
    seen_hard_links: Mutex<HashSet<(u64, u64)>>,
    /// Directories already visited in this scan, by `(device, inode)`.
    seen_dirs: Mutex<HashSet<(u64, u64)>>,
    /// Directories put off until the rest of the scan is done.
    deferred: Mutex<Vec<PathBuf>>,
}

/// Bytes a file occupies on disk (allocated blocks), which is what a disk
/// space tool should show. It differs from the apparent length for sparse
/// files, compressed files and tiny files that still use a whole block.
/// Windows has no cheap equivalent in std, so it falls back to the length.
pub fn disk_usage(meta: &fs::Metadata) -> u64 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        meta.blocks() * 512
    }
    #[cfg(not(unix))]
    {
        meta.len()
    }
}

/// `(device, inode)` of a file with more than one hard link, so each linked
/// file is only counted once per scan. `None` for ordinary files.
fn hard_link_id(meta: &fs::Metadata) -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (meta.nlink() > 1).then(|| (meta.dev(), meta.ino()))
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        None
    }
}

/// `(device, inode)` of a directory, used to visit each directory once even
/// when it is reachable through more than one path (macOS firmlinks such as
/// `/Users` → `/System/Volumes/Data/Users`, Linux bind mounts).
fn dir_id(meta: &fs::Metadata) -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some((meta.dev(), meta.ino()))
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        None
    }
}

/// macOS keeps user data on a separate volume mounted here, and firmlinks
/// `/Users`, `/Applications`, `/Library`, `/private`, ... into it. A scan that
/// contains this folder scans it last, so the data is counted under the
/// familiar paths and only what is unique to the volume (Spotlight index,
/// document revisions, ...) stays under it.
const MACOS_DATA_VOLUME: &str = "/System/Volumes/Data";

/// The directory a scan puts off until the end, on this platform.
fn deferred_volume() -> Option<&'static Path> {
    cfg!(target_os = "macos").then(|| Path::new(MACOS_DATA_VOLUME))
}

/// Minimum time between progress-path updates (and the repaints they request).
const PATH_UPDATE_INTERVAL_MS: u64 = 50;

impl Default for ScanProgress {
    fn default() -> Self {
        Self::new()
    }
}

impl ScanProgress {
    pub fn new() -> Self {
        ScanProgress {
            items_scanned: AtomicU64::new(0),
            bytes_scanned: AtomicU64::new(0),
            current_path: Mutex::new(String::new()),
            done: Mutex::new(false),
            result: Mutex::new(None),
            duration: Mutex::new(None),
            started: Instant::now(),
            last_path_update_ms: AtomicU64::new(0),
            seen_hard_links: Mutex::new(HashSet::new()),
            seen_dirs: Mutex::new(HashSet::new()),
            deferred: Mutex::new(Vec::new()),
        }
    }

    /// Disk usage of a file, or 0 if it is another hard link to a file this
    /// scan already counted.
    pub fn file_usage(&self, meta: &fs::Metadata) -> u64 {
        match hard_link_id(meta) {
            Some(id) if !self.seen_hard_links.lock().unwrap().insert(id) => 0,
            _ => disk_usage(meta),
        }
    }

    /// Whether enough time has passed to publish a new `current_path`.
    /// Only one thread wins each interval.
    fn should_update_path(&self) -> bool {
        let now = self.started.elapsed().as_millis() as u64;
        let last = self.last_path_update_ms.load(Ordering::Relaxed);
        now.saturating_sub(last) >= PATH_UPDATE_INTERVAL_MS
            && self
                .last_path_update_ms
                .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
    }
}

impl FileNode {
    pub fn scan_async(
        path: std::path::PathBuf,
        progress: Arc<ScanProgress>,
        excluded: HashSet<PathBuf>,
        ctx: eframe::egui::Context,
    ) {
        let excluded = Arc::new(excluded);
        std::thread::spawn(move || {
            let start = Instant::now();
            let result = FileNode::scan(&path, &progress, &excluded, &ctx);
            let elapsed = start.elapsed();
            *progress.duration.lock().unwrap() = Some(elapsed);
            *progress.result.lock().unwrap() = Some(result);
            *progress.done.lock().unwrap() = true;
            ctx.request_repaint();
        });
    }

    /// Scan `path` recursively. Each directory is counted once, however many
    /// paths lead to it.
    pub fn scan(
        path: &Path,
        progress: &Arc<ScanProgress>,
        excluded: &Arc<HashSet<PathBuf>>,
        ctx: &eframe::egui::Context,
    ) -> FileNode {
        FileNode::scan_deferring(path, progress, excluded, ctx, deferred_volume())
    }

    /// `scan`, putting `defer` off until the end when the scan contains it.
    fn scan_deferring(
        path: &Path,
        progress: &Arc<ScanProgress>,
        excluded: &Arc<HashSet<PathBuf>>,
        ctx: &eframe::egui::Context,
        defer: Option<&Path>,
    ) -> FileNode {
        let mut root = FileNode::scan_entry(path, path, progress, excluded, ctx, defer)
            .unwrap_or_else(|| {
                FileNode::new(path.to_string_lossy().to_string(), 0, Vec::new(), true)
            });

        // Now that everything else is counted, scan what was put off; any
        // directory already seen through another path is left out of it.
        // Nothing is deferred in this pass, or the deferred directory would
        // just be put off again and never scanned.
        let deferred = std::mem::take(&mut *progress.deferred.lock().unwrap());
        for dir in deferred {
            let Ok(relative) = dir.strip_prefix(path) else {
                continue;
            };
            let components: Vec<String> = relative
                .components()
                .map(|c| c.as_os_str().to_string_lossy().to_string())
                .collect();
            if let Some(node) = FileNode::scan_entry(&dir, path, progress, excluded, ctx, None) {
                root.graft(&components, node);
            }
        }
        root
    }

    /// Insert `node` at `path` (names below `self`, the last being `node`'s
    /// own), adding its size to every directory on the way. Missing
    /// intermediate directories are created.
    fn graft(&mut self, path: &[String], node: FileNode) {
        self.size += node.size;
        match path {
            [] => {}
            [_] => self.children.push(node),
            [first, rest @ ..] => {
                let pos = match self
                    .children
                    .iter()
                    .position(|c| c.is_dir && &c.name == first)
                {
                    Some(pos) => pos,
                    None => {
                        self.children
                            .push(FileNode::new(first.clone(), 0, Vec::new(), true));
                        self.children.len() - 1
                    }
                };
                self.children[pos].graft(rest, node);
            }
        }
        self.children
            .sort_unstable_by_key(|c| std::cmp::Reverse(c.size));
    }

    /// Scan one entry. Returns `None` for a directory that is skipped here:
    /// already visited through another path, or put off until later (`defer`,
    /// unless it is the scan root).
    fn scan_entry(
        path: &Path,
        root: &Path,
        progress: &Arc<ScanProgress>,
        excluded: &Arc<HashSet<PathBuf>>,
        ctx: &eframe::egui::Context,
        defer: Option<&Path>,
    ) -> Option<FileNode> {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| path.to_string_lossy().to_string());

        // Use symlink_metadata to avoid following symlinks for the check
        let meta = match fs::symlink_metadata(path) {
            Ok(m) => m,
            Err(_) => {
                return Some(FileNode::new(name, 0, Vec::new(), false));
            }
        };

        // Skip symlinks
        if meta.is_symlink() {
            return Some(FileNode::new(name, 0, Vec::new(), false));
        }

        if meta.is_file() {
            let size = progress.file_usage(&meta);
            progress.items_scanned.fetch_add(1, Ordering::Relaxed);
            progress.bytes_scanned.fetch_add(size, Ordering::Relaxed);
            return Some(FileNode::new(name, size, Vec::new(), false));
        }

        // Skip excluded directories.
        if excluded.contains(path) {
            return Some(FileNode::new(name, 0, Vec::new(), true));
        }

        // Put the macOS data volume off until the end (see MACOS_DATA_VOLUME),
        // unless it is what the user asked to scan.
        if path != root && defer == Some(path) {
            progress.deferred.lock().unwrap().push(path.to_path_buf());
            return None;
        }

        // Count each directory once. This lock is taken per directory, not
        // per file, so it stays cheap.
        if let Some(id) = dir_id(&meta) {
            if !progress.seen_dirs.lock().unwrap().insert(id) {
                return None;
            }
        }

        // Directory: update progress path, at most every PATH_UPDATE_INTERVAL_MS.
        progress.items_scanned.fetch_add(1, Ordering::Relaxed);
        if progress.should_update_path() {
            if let Ok(mut current) = progress.current_path.try_lock() {
                *current = path.to_string_lossy().to_string();
            }
            ctx.request_repaint();
        }

        let read_dir = match fs::read_dir(path) {
            Ok(rd) => rd,
            Err(_) => {
                return Some(FileNode::new(name, 0, Vec::new(), true));
            }
        };

        // Files are handled inline (one lstat each, as before); only
        // subdirectories become parallel tasks. Progress counters are updated
        // once per directory instead of once per file, which avoids contention
        // between threads on the shared atomics.
        let mut children: Vec<FileNode> = Vec::new();
        let mut subdirs: Vec<PathBuf> = Vec::new();
        let mut file_count = 0u64;
        let mut file_bytes = 0u64;
        for entry in read_dir.filter_map(|e| e.ok()) {
            // DirEntry::file_type usually needs no extra syscall.
            let Ok(ft) = entry.file_type() else { continue };
            if ft.is_symlink() {
                continue;
            }
            if ft.is_dir() {
                subdirs.push(entry.path());
                continue;
            }
            // Regular files count their disk usage. Other entries (sockets, FIFOs,
            // devices) are zero-size files; they used to show up as empty
            // directories.
            let size = match entry.metadata() {
                Ok(m) if m.is_file() => progress.file_usage(&m),
                Ok(_) => 0,
                Err(_) => {
                    children.push(FileNode::new(
                        entry.file_name().to_string_lossy().to_string(),
                        0,
                        Vec::new(),
                        false,
                    ));
                    continue;
                }
            };
            file_count += 1;
            file_bytes += size;
            children.push(FileNode::new(
                entry.file_name().to_string_lossy().to_string(),
                size,
                Vec::new(),
                false,
            ));
        }
        progress
            .items_scanned
            .fetch_add(file_count, Ordering::Relaxed);
        progress
            .bytes_scanned
            .fetch_add(file_bytes, Ordering::Relaxed);

        // Scan subdirectories in parallel with rayon
        children.par_extend(
            subdirs
                .par_iter()
                .filter_map(|dir| FileNode::scan_entry(dir, root, progress, excluded, ctx, defer)),
        );

        let total_size: u64 = children.iter().map(|c| c.size).sum();

        // Sort children by size descending for better treemap layout
        children.sort_unstable_by_key(|c| std::cmp::Reverse(c.size));

        Some(FileNode::new(name, total_size, children, true))
    }
}

pub fn format_size(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = KB * 1024.0;
    const GB: f64 = MB * 1024.0;
    const TB: f64 = GB * 1024.0;

    let b = bytes as f64;
    if b >= TB {
        format!("{:.1} TB", b / TB)
    } else if b >= GB {
        format!("{:.1} GB", b / GB)
    } else if b >= MB {
        format!("{:.1} MB", b / MB)
    } else if b >= KB {
        format!("{:.1} KB", b / KB)
    } else {
        format!("{} B", bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_size_bytes() {
        assert_eq!(format_size(0), "0 B");
        assert_eq!(format_size(1), "1 B");
        assert_eq!(format_size(512), "512 B");
        assert_eq!(format_size(1023), "1023 B");
    }

    #[test]
    fn format_size_kilobytes() {
        assert_eq!(format_size(1024), "1.0 KB");
        assert_eq!(format_size(1536), "1.5 KB");
        assert_eq!(format_size(1024 * 1023), "1023.0 KB");
    }

    #[test]
    fn format_size_megabytes() {
        assert_eq!(format_size(1024 * 1024), "1.0 MB");
        assert_eq!(format_size(1024 * 1024 * 500), "500.0 MB");
    }

    #[test]
    fn format_size_gigabytes() {
        assert_eq!(format_size(1024 * 1024 * 1024), "1.0 GB");
        assert_eq!(format_size(1024u64 * 1024 * 1024 * 10), "10.0 GB");
    }

    #[test]
    fn format_size_terabytes() {
        assert_eq!(format_size(1024u64 * 1024 * 1024 * 1024), "1.0 TB");
        assert_eq!(format_size(1024u64 * 1024 * 1024 * 1024 * 5), "5.0 TB");
    }

    #[test]
    fn file_node_construction() {
        let node = FileNode::new("test.txt".to_string(), 1024, Vec::new(), false);
        assert_eq!(node.name, "test.txt");
        assert_eq!(node.size, 1024);
        assert!(!node.is_dir);
        assert!(node.children.is_empty());
    }

    #[test]
    fn file_node_directory_with_children() {
        let child1 = FileNode::new("big.bin".to_string(), 2000, Vec::new(), false);
        let child2 = FileNode::new("small.txt".to_string(), 100, Vec::new(), false);
        let dir = FileNode::new("mydir".to_string(), 2100, vec![child1, child2], true);
        assert!(dir.is_dir);
        assert_eq!(dir.children.len(), 2);
        assert_eq!(dir.size, 2100);
    }

    #[test]
    fn scan_sums_nested_sizes_and_skips_symlinks() {
        let root = std::env::temp_dir().join(format!("alocir-scan-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("a/b")).unwrap();
        fs::write(root.join("top.txt"), vec![0u8; 10]).unwrap();
        fs::write(root.join("a/one.bin"), vec![0u8; 100]).unwrap();
        fs::write(root.join("a/b/two.bin"), vec![0u8; 1000]).unwrap();
        fs::create_dir_all(root.join("empty")).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(root.join("a"), root.join("link")).unwrap();

        let usage = |p: &str| disk_usage(&fs::metadata(root.join(p)).unwrap());
        let (top, one, two) = (usage("top.txt"), usage("a/one.bin"), usage("a/b/two.bin"));

        let progress = Arc::new(ScanProgress::new());
        let excluded = Arc::new(HashSet::new());
        let ctx = eframe::egui::Context::default();
        let node = FileNode::scan(&root, &progress, &excluded, &ctx);
        let _ = fs::remove_dir_all(&root);

        assert!(node.is_dir);
        assert_eq!(node.size, top + one + two);
        // The symlink is skipped; "empty" is last (size 0).
        let mut names: Vec<&str> = node.children.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names.pop(), Some("empty"));
        names.sort();
        assert_eq!(names, ["a", "top.txt"]);
        let a = node.children.iter().find(|c| c.name == "a").unwrap();
        assert_eq!(a.size, one + two);
        assert!(a.children.iter().any(|c| c.name == "b" && c.is_dir));
        // root, a, b, empty (dirs) + 3 files
        assert_eq!(progress.items_scanned.load(Ordering::Relaxed), 7);
        assert_eq!(
            progress.bytes_scanned.load(Ordering::Relaxed),
            top + one + two
        );
    }

    #[cfg(unix)]
    #[test]
    fn scan_counts_disk_usage_and_hard_links_once() {
        let root = std::env::temp_dir().join(format!("alocir-hl-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("x")).unwrap();
        fs::create_dir_all(root.join("y")).unwrap();
        fs::write(root.join("x/data.bin"), vec![1u8; 64 * 1024]).unwrap();
        fs::hard_link(root.join("x/data.bin"), root.join("y/same.bin")).unwrap();
        // Sparse file: 100 MB long, almost nothing allocated.
        fs::File::create(root.join("sparse.img"))
            .unwrap()
            .set_len(100 * 1024 * 1024)
            .unwrap();
        let data = disk_usage(&fs::metadata(root.join("x/data.bin")).unwrap());

        let progress = Arc::new(ScanProgress::new());
        let excluded = Arc::new(HashSet::new());
        let ctx = eframe::egui::Context::default();
        let node = FileNode::scan(&root, &progress, &excluded, &ctx);
        let sparse = node
            .children
            .iter()
            .find(|c| c.name == "sparse.img")
            .unwrap()
            .size;
        let _ = fs::remove_dir_all(&root);

        assert!(data >= 64 * 1024);
        assert!(
            sparse < 1024 * 1024,
            "sparse file counted as {sparse} bytes"
        );
        // The hard-linked file counts once, in whichever folder was seen first.
        assert_eq!(node.size, data + sparse);
    }

    #[test]
    fn scan_skips_excluded_dirs() {
        let root = std::env::temp_dir().join(format!("alocir-excl-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("skip")).unwrap();
        fs::write(root.join("skip/big.bin"), vec![0u8; 50_000]).unwrap();
        fs::write(root.join("keep.bin"), vec![0u8; 5]).unwrap();
        let keep = disk_usage(&fs::metadata(root.join("keep.bin")).unwrap());

        let progress = Arc::new(ScanProgress::new());
        let excluded = Arc::new(HashSet::from([root.join("skip")]));
        let ctx = eframe::egui::Context::default();
        let node = FileNode::scan(&root, &progress, &excluded, &ctx);
        let _ = fs::remove_dir_all(&root);

        assert_eq!(node.size, keep);
    }

    #[cfg(unix)]
    #[test]
    fn directory_reached_twice_is_counted_once() {
        // A second path to an already-visited directory (a firmlink or bind
        // mount in real life) is skipped, because it has the same
        // (device, inode). Simulate that by scanning a subdirectory again with
        // the same progress state.
        let root = std::env::temp_dir().join(format!("alocir-dirid-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("data/users")).unwrap();
        fs::write(root.join("data/users/f.bin"), vec![1u8; 8192]).unwrap();

        let progress = Arc::new(ScanProgress::new());
        let excluded = Arc::new(HashSet::new());
        let ctx = eframe::egui::Context::default();
        let first = FileNode::scan(&root, &progress, &excluded, &ctx);
        let again = FileNode::scan_entry(
            &root.join("data/users"),
            &root,
            &progress,
            &excluded,
            &ctx,
            None,
        );
        let _ = fs::remove_dir_all(&root);

        assert!(first.size > 0);
        assert!(
            again.is_none(),
            "an already-visited directory must be skipped"
        );
    }

    #[test]
    fn graft_inserts_node_and_updates_ancestor_sizes() {
        let leaf = |name: &str, size| FileNode::new(name.to_string(), size, Vec::new(), false);
        let mut root = FileNode::new(
            "/".into(),
            10,
            vec![FileNode::new(
                "System".into(),
                10,
                vec![leaf("kernel", 10)],
                true,
            )],
            true,
        );
        let data = FileNode::new("Data".into(), 50, vec![leaf(".Spotlight-V100", 50)], true);
        root.graft(&["System".into(), "Volumes".into(), "Data".into()], data);

        assert_eq!(root.size, 60);
        let system = &root.children[0];
        assert_eq!(system.size, 60);
        // "Volumes" was created and sorted ahead of the smaller "kernel".
        assert_eq!(system.children[0].name, "Volumes");
        assert_eq!(system.children[0].size, 50);
        assert_eq!(system.children[0].children[0].name, "Data");
    }

    #[test]
    fn data_volume_is_deferred_only_on_macos() {
        assert_eq!(
            deferred_volume(),
            cfg!(target_os = "macos").then(|| Path::new("/System/Volumes/Data"))
        );
    }

    #[test]
    fn deferred_directory_is_scanned_at_the_end() {
        // Stands in for /System/Volumes/Data, which tests can't create: it is
        // put off, then scanned and grafted back in. It used to be put off a
        // second time and left out.
        let root = std::env::temp_dir().join(format!("alocir-defer-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("System/Volumes/Data/.Spotlight-V100")).unwrap();
        fs::create_dir_all(root.join("Users")).unwrap();
        fs::write(root.join("Users/u.bin"), vec![1u8; 20_000]).unwrap();
        fs::write(
            root.join("System/Volumes/Data/.Spotlight-V100/index"),
            vec![1u8; 50_000],
        )
        .unwrap();
        let usage = |p: &str| disk_usage(&fs::metadata(root.join(p)).unwrap());
        let (u, index) = (
            usage("Users/u.bin"),
            usage("System/Volumes/Data/.Spotlight-V100/index"),
        );

        let progress = Arc::new(ScanProgress::new());
        let excluded = Arc::new(HashSet::new());
        let ctx = eframe::egui::Context::default();
        let data = root.join("System/Volumes/Data");
        let node = FileNode::scan_deferring(&root, &progress, &excluded, &ctx, Some(&data));
        let scanned_whole =
            FileNode::scan_deferring(&root, &Arc::new(ScanProgress::new()), &excluded, &ctx, None);
        let _ = fs::remove_dir_all(&root);

        assert_eq!(node.size, u + index);
        assert_eq!(node.size, scanned_whole.size);
        let system = node.children.iter().find(|c| c.name == "System").unwrap();
        let volumes = system
            .children
            .iter()
            .find(|c| c.name == "Volumes")
            .unwrap();
        assert_eq!(volumes.children.len(), 1);
        assert_eq!(volumes.children[0].name, "Data");
        assert_eq!(volumes.children[0].size, index);
        // root, Users, System, Volumes, Data, .Spotlight-V100 + 2 files
        assert_eq!(progress.items_scanned.load(Ordering::Relaxed), 8);
    }

    #[test]
    fn scan_progress_initial_state() {
        let progress = ScanProgress::new();
        assert_eq!(progress.items_scanned.load(Ordering::Relaxed), 0);
        assert_eq!(progress.bytes_scanned.load(Ordering::Relaxed), 0);
        assert!(!*progress.done.lock().unwrap());
        assert!(progress.result.lock().unwrap().is_none());
        assert!(progress.duration.lock().unwrap().is_none());
    }
}
