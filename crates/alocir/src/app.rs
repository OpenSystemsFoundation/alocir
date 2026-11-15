mod views;

use eframe::egui;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::Arc;

use alocir_shared::scanner::{FileNode, ScanProgress};
use alocir_shared::settings::{show_settings_window, SettingsState};

struct RenameState {
    path: PathBuf,
    is_dir: bool,
    new_name: String,
    error: Option<String>,
    /// Focus the text field (and select the name) on the next frame.
    focus_pending: bool,
}

pub struct TreemapApp {
    root: Option<FileNode>,
    root_path: String,
    scan_path: PathBuf,
    excluded: HashSet<PathBuf>,
    nav_stack: Vec<usize>,
    scan_progress: Arc<ScanProgress>,
    scanning: bool,
    rename_state: Option<RenameState>,
    saved_nav_names: Option<Vec<String>>,
    scan_duration: Option<std::time::Duration>,
    settings: SettingsState,
    /// When the scan in progress started, for the elapsed-time display.
    scan_started: std::time::Instant,
    /// Index (in the current node's children) of the tile under the pointer
    /// last frame, shown in the status bar.
    hovered: Option<usize>,
    /// An error to show in the status bar for a few seconds.
    notice: Option<(String, std::time::Instant)>,
    // Filesystem watcher for live updates
    _watcher: Option<RecommendedWatcher>,
    watch_rx: Option<mpsc::Receiver<notify::Result<notify::Event>>>,
    /// What `_watcher` watches (or last failed to watch), so the watcher is
    /// only replaced when the target changes.
    watched: Option<(PathBuf, RecursiveMode)>,
    /// `settings.watch_subfolders` as last applied by `ensure_watching`.
    watch_subfolders_applied: bool,
    /// A recursive watch failed (e.g. Linux's inotify watch limit), so only
    /// the current directory is watched until the setting is toggled.
    recursive_watch_failed: bool,
    /// `scan_path` with symlinks resolved. Watchers may report either form
    /// (FSEvents reports `/private/var/...` for `/var/...`).
    scan_path_canonical: PathBuf,
    // Background scans of directories that appeared or need re-reading
    dir_scan_tx: mpsc::Sender<(PathBuf, FileNode)>,
    dir_scan_rx: mpsc::Receiver<(PathBuf, FileNode)>,
    /// Directories being scanned in the background (keyed by path under
    /// `scan_path`), and whether they changed again since their scan started.
    pending_scans: HashMap<PathBuf, bool>,
}

impl TreemapApp {
    pub fn new(
        path: PathBuf,
        excluded: HashSet<PathBuf>,
        settings: SettingsState,
        ctx: &egui::Context,
    ) -> Self {
        let root_path = path.to_string_lossy().to_string();
        let progress = Arc::new(ScanProgress::new());
        let (dir_scan_tx, dir_scan_rx) = mpsc::channel();
        FileNode::scan_async(
            path.clone(),
            Arc::clone(&progress),
            excluded.clone(),
            ctx.clone(),
        );
        let scan_path_canonical = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
        let watch_subfolders_applied = settings.watch_subfolders;
        TreemapApp {
            root: None,
            root_path,
            scan_path: path,
            excluded,
            nav_stack: Vec::new(),
            scan_progress: progress,
            scanning: true,
            rename_state: None,
            saved_nav_names: None,
            scan_duration: None,
            settings,
            scan_started: std::time::Instant::now(),
            hovered: None,
            notice: None,
            _watcher: None,
            watch_rx: None,
            watched: None,
            watch_subfolders_applied,
            recursive_watch_failed: false,
            scan_path_canonical,
            dir_scan_tx,
            dir_scan_rx,
            pending_scans: HashMap::new(),
        }
    }

    fn current_node(&self) -> Option<&FileNode> {
        let mut node = self.root.as_ref()?;
        for &idx in &self.nav_stack {
            if idx < node.children.len() {
                node = &node.children[idx];
            } else {
                return None;
            }
        }
        Some(node)
    }

    fn current_dir_path(&self) -> PathBuf {
        let mut path = self.scan_path.clone();
        if let Some(root) = &self.root {
            let mut node = root;
            for &idx in &self.nav_stack {
                if idx < node.children.len() {
                    node = &node.children[idx];
                    path = path.join(&node.name);
                }
            }
        }
        path
    }

    fn nav_names(&self) -> Vec<String> {
        let mut names = Vec::new();
        if let Some(root) = &self.root {
            let mut node = root;
            for &idx in &self.nav_stack {
                if idx < node.children.len() {
                    node = &node.children[idx];
                    names.push(node.name.clone());
                }
            }
        }
        names
    }

    fn restore_nav(root: &FileNode, names: &[String]) -> Vec<usize> {
        let mut stack = Vec::new();
        let mut node = root;
        for name in names {
            if let Some(idx) = node.children.iter().position(|c| &c.name == name) {
                stack.push(idx);
                node = &node.children[idx];
            } else {
                break;
            }
        }
        stack
    }

    /// What to watch, and how: the whole scan root when watching subfolders
    /// (one FSEvents stream / ReadDirectoryChangesW handle, so it never needs
    /// re-watching on navigation), otherwise just the directory on screen.
    fn watch_target(&self) -> (PathBuf, RecursiveMode) {
        if self.settings.watch_subfolders && !self.recursive_watch_failed {
            (self.scan_path.clone(), RecursiveMode::Recursive)
        } else {
            (self.current_dir_path(), RecursiveMode::NonRecursive)
        }
    }

    fn start_watching(
        &mut self,
        dir: &Path,
        mode: RecursiveMode,
        ctx: &egui::Context,
    ) -> notify::Result<()> {
        // Release the old watches first: inotify's are a limited resource.
        self._watcher = None;
        self.watch_rx = None;
        let (tx, rx) = mpsc::channel();
        let ctx_clone = ctx.clone();
        let mut watcher = notify::recommended_watcher(move |res| {
            let _ = tx.send(res);
            ctx_clone.request_repaint();
        })?;
        watcher.watch(dir, mode)?;
        self._watcher = Some(watcher);
        self.watch_rx = Some(rx);
        Ok(())
    }

    /// (Re)start the watcher if the setting or (when not recursive) the
    /// current directory changed. Cheap to call every frame.
    fn ensure_watching(&mut self, ctx: &egui::Context) {
        if self.watch_subfolders_applied != self.settings.watch_subfolders {
            self.watch_subfolders_applied = self.settings.watch_subfolders;
            self.recursive_watch_failed = false;
            self.settings.watch_status = None;
        }
        let target = self.watch_target();
        if self.watched.as_ref() == Some(&target) {
            return;
        }
        let result = self.start_watching(&target.0, target.1, ctx);
        // Remember the target even if watching failed, so a failure isn't
        // retried every frame.
        let recursive = target.1 == RecursiveMode::Recursive;
        self.watched = Some(target);
        if let Err(e) = result {
            if recursive {
                self.fall_back_to_non_recursive(&e, ctx);
            }
        }
    }

    /// A recursive watch failed: say why and watch only the current directory.
    fn fall_back_to_non_recursive(&mut self, err: &notify::Error, ctx: &egui::Context) {
        self.recursive_watch_failed = true;
        self.settings.watch_status = Some(format!(
            "Couldn't watch subfolders ({err}). Only the folder shown is watched."
        ));
        self.ensure_watching(ctx);
    }

    fn process_watch_events(&mut self, ctx: &egui::Context) {
        // Results of background directory scans. A result is only applied
        // while its scan is still wanted (a scan of an ancestor supersedes
        // it), and re-run if the directory changed while it was running.
        while let Ok((path, node)) = self.dir_scan_rx.try_recv() {
            let Some(changed_since) = self.pending_scans.remove(&path) else {
                continue;
            };
            self.apply_scanned_dir(&path, node);
            if changed_since {
                self.scan_dir_in_background(path, ctx);
            }
        }

        let Some(rx) = &self.watch_rx else {
            return;
        };

        // Collect the batch, deduplicating paths so a big copy doesn't
        // reconcile the same path thousands of times in one frame.
        let mut paths: Vec<PathBuf> = Vec::new();
        let mut rescans: Vec<PathBuf> = Vec::new();
        let mut seen: HashSet<PathBuf> = HashSet::new();
        let mut watch_error = None;
        while let Ok(result) = rx.try_recv() {
            match result {
                Ok(event) if event.need_rescan() => {
                    // Events were dropped or coalesced (FSEvents
                    // MustScanSubDirs, inotify queue overflow).
                    if event.paths.is_empty() {
                        rescans.push(self.scan_path.clone());
                    } else {
                        rescans.extend(event.paths);
                    }
                }
                Ok(event) if matches!(event.kind, notify::EventKind::Access(_)) => {}
                Ok(event) => {
                    for path in event.paths {
                        if seen.insert(path.clone()) {
                            paths.push(path);
                        }
                    }
                }
                // inotify reports running out of watches for new directories
                // inside a recursive watch this way.
                Err(e) if matches!(e.kind, notify::ErrorKind::MaxFilesWatch) => {
                    watch_error = Some(e);
                }
                Err(_) => {}
            }
        }

        // Scans already running may have read these directories before the
        // changes happened.
        for path in paths.iter().chain(&rescans) {
            let path = self.to_scan_path_form(path);
            for dir in path.ancestors() {
                if let Some(changed) = self.pending_scans.get_mut(dir) {
                    *changed = true;
                }
            }
        }

        // Rather than trusting the event kind (macOS reports renames, moves and
        // Finder trashing as "name modified" events, often without saying which
        // side of the rename a path is), look at what is on disk now.
        for path in &paths {
            self.reconcile_path(path, ctx);
        }
        for path in &rescans {
            self.rescan_dir(path, ctx);
        }

        if let Some(e) = watch_error {
            if self
                .watched
                .as_ref()
                .is_some_and(|w| w.1 == RecursiveMode::Recursive)
            {
                self.fall_back_to_non_recursive(&e, ctx);
            }
        }
    }

    /// `path` rewritten to start with `scan_path`, if it is under the
    /// canonical form of the scan root instead; otherwise unchanged.
    fn to_scan_path_form(&self, path: &Path) -> PathBuf {
        if !path.starts_with(&self.scan_path) {
            if let Ok(rel) = path.strip_prefix(&self.scan_path_canonical) {
                return self.scan_path.join(rel);
            }
        }
        path.to_path_buf()
    }

    /// The names leading from the scan root to `path` (empty for the root
    /// itself), or `None` if `path` is outside the scan root or inside an
    /// excluded directory.
    fn rel_names(&self, path: &Path) -> Option<Vec<String>> {
        let path = self.to_scan_path_form(path);
        let rel = path.strip_prefix(&self.scan_path).ok()?;
        let mut names = Vec::new();
        for component in rel.components() {
            match component {
                std::path::Component::Normal(name) => names.push(name.to_string_lossy().into()),
                _ => return None,
            }
        }
        // The scanner keeps excluded directories empty.
        if path
            .ancestors()
            .skip(1)
            .take(names.len())
            .any(|dir| self.excluded.contains(dir))
        {
            return None;
        }
        Some(names)
    }

    fn path_for(&self, names: &[String]) -> PathBuf {
        let mut path = self.scan_path.clone();
        path.extend(names);
        path
    }

    /// The directory node at `names` below the root, if the tree has it.
    fn dir_at(&self, names: &[String]) -> Option<&FileNode> {
        let mut node = self.root.as_ref()?;
        for name in names {
            node = node.children.iter().find(|c| c.is_dir && &c.name == name)?;
        }
        Some(node)
    }

    /// How many leading `names` the tree has as nested directories.
    fn known_depth(&self, names: &[String]) -> usize {
        let Some(mut node) = self.root.as_ref() else {
            return 0;
        };
        for (depth, name) in names.iter().enumerate() {
            match node.children.iter().find(|c| c.is_dir && &c.name == name) {
                Some(child) => node = child,
                None => return depth,
            }
        }
        names.len()
    }

    /// Bring the tree's entry for `path`, anywhere under the scan root, in
    /// line with the disk: add it, update its size, or remove it, fixing the
    /// sizes of every directory above it. If a directory between the root and
    /// `path` isn't in the tree, the highest missing one is reconciled
    /// instead. Paths outside the scan root, and the root itself, are ignored.
    fn reconcile_path(&mut self, path: &Path, ctx: &egui::Context) {
        if self.root.is_none() {
            return;
        }
        let Some(names) = self.rel_names(path) else {
            return;
        };
        let Some((name, parents)) = names.split_last() else {
            return;
        };
        let known = self.known_depth(parents);
        if known < parents.len() {
            let missing = self.path_for(&names[..=known]);
            self.reconcile_path(&missing, ctx);
            return;
        }
        let path = self.path_for(&names);

        match std::fs::symlink_metadata(&path) {
            // The scanner skips symlinks, so treat them as absent.
            Err(_) => self.update_child(parents, name, None),
            Ok(m) if m.is_symlink() => self.update_child(parents, name, None),
            Ok(m) if m.is_dir() => {
                let known = self
                    .dir_at(parents)
                    .is_some_and(|n| n.children.iter().any(|c| c.is_dir && &c.name == name));
                if !known {
                    // Show it right away, then fill in its real size from a
                    // full scan off the UI thread.
                    let placeholder = FileNode {
                        name: name.clone(),
                        size: 0,
                        children: Vec::new(),
                        is_dir: true,
                    };
                    self.update_child(parents, name, Some(placeholder));
                    self.scan_dir_in_background(path, ctx);
                }
            }
            Ok(m) => {
                let file = FileNode {
                    name: name.clone(),
                    size: if m.is_file() {
                        alocir_shared::scanner::disk_usage(&m)
                    } else {
                        0
                    },
                    children: Vec::new(),
                    is_dir: false,
                };
                self.update_child(parents, name, Some(file));
            }
        }
    }

    /// Events were dropped for `path`: re-scan it in the background, or the
    /// nearest directory above it that the tree has (the scan root if
    /// nothing better is known).
    fn rescan_dir(&mut self, path: &Path, ctx: &egui::Context) {
        if self
            .to_scan_path_form(path)
            .strip_prefix(&self.scan_path)
            .is_err()
        {
            // Outside the scan root (e.g. a whole-volume rescan): be safe.
            self.scan_dir_in_background(self.scan_path.clone(), ctx);
            return;
        }
        // `None` here means inside an excluded directory: nothing to do.
        let Some(names) = self.rel_names(path) else {
            return;
        };
        let depth = self.known_depth(&names);
        self.scan_dir_in_background(self.path_for(&names[..depth]), ctx);
    }

    /// Scan the directory `path` (under `scan_path`) on a background thread;
    /// the result is applied by `process_watch_events`. If it, or a directory
    /// above it, is already being scanned, that scan is just marked to run
    /// again when it finishes.
    fn scan_dir_in_background(&mut self, path: PathBuf, ctx: &egui::Context) {
        for dir in path.ancestors() {
            if let Some(changed) = self.pending_scans.get_mut(dir) {
                *changed = true;
                return;
            }
        }
        // This scan supersedes any running below it.
        self.pending_scans.retain(|p, _| !p.starts_with(&path));
        self.pending_scans.insert(path.clone(), false);

        let tx = self.dir_scan_tx.clone();
        let excluded = Arc::new(self.excluded.clone());
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let progress = Arc::new(ScanProgress::new());
            let node = FileNode::scan(&path, &progress, &excluded, &ctx);
            if tx.send((path, node)).is_ok() {
                ctx.request_repaint();
            }
        });
    }

    /// Put a finished background scan of `path` into the tree, if the
    /// directory is still there on disk and its parent is in the tree.
    fn apply_scanned_dir(&mut self, path: &Path, mut node: FileNode) {
        let Some(names) = self.rel_names(path) else {
            return;
        };
        if !std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir()) {
            // Gone (or replaced) since; its own event handles that.
            return;
        }
        match names.split_last() {
            None => {
                // The whole tree was re-scanned.
                let nav = self.nav_names();
                if let Some(root) = &mut self.root {
                    node.name = std::mem::take(&mut root.name);
                    *root = node;
                    self.nav_stack = Self::restore_nav(root, &nav);
                }
            }
            Some((name, parents)) => self.update_child(parents, name, Some(node)),
        }
    }

    /// Replace the child `name` of the directory at `parents` with `new`
    /// (inserting it if absent; `None` removes it). Sizes of every directory
    /// up to the root are adjusted and each level's children stay sorted by
    /// size. Re-sorting can move directories on the navigation path, so
    /// `nav_stack` is re-derived by name afterwards. Does nothing if
    /// `parents` isn't in the tree.
    fn update_child(&mut self, parents: &[String], name: &str, new: Option<FileNode>) {
        let nav = self.nav_names();
        let Some(root) = self.root.as_mut() else {
            return;
        };
        if replace_child(root, parents, name, new).is_some() {
            self.nav_stack = Self::restore_nav(root, &nav);
        }
    }

    /// Remove a child of the current node by name, updating ancestor sizes.
    fn remove_child(&mut self, name: &str) {
        let parents = self.nav_names();
        self.update_child(&parents, name, None);
    }

    fn trigger_rescan(&mut self, ctx: &egui::Context) {
        self.saved_nav_names = Some(self.nav_names());
        let progress = Arc::new(ScanProgress::new());
        self.scan_progress = Arc::clone(&progress);
        self.scanning = true;
        self.scan_duration = None;
        FileNode::scan_async(
            self.scan_path.clone(),
            progress,
            self.excluded.clone(),
            ctx.clone(),
        );
    }

    fn do_trash(&mut self, path: PathBuf, _ctx: &egui::Context) {
        match move_to_trash(&path) {
            Ok(()) => {
                if let Some(name) = path.file_name() {
                    self.remove_child(&name.to_string_lossy());
                }
            }
            Err(e) => {
                eprintln!("Move to trash failed: {}", e);
                self.notice = Some((
                    format!("Could not move to Trash: {e}"),
                    std::time::Instant::now(),
                ));
            }
        }
    }
}

impl eframe::App for TreemapApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.settings.apply_theme(ctx);

        if self.scanning {
            let done = *self.scan_progress.done.lock().unwrap();
            if done {
                self.root = self.scan_progress.result.lock().unwrap().take();
                self.scan_duration = self.scan_progress.duration.lock().unwrap().take();
                self.scanning = false;
                if let Some(names) = self.saved_nav_names.take() {
                    if let Some(root) = &self.root {
                        self.nav_stack = Self::restore_nav(root, &names);
                    }
                }
                self.ensure_watching(ctx);
            }
        }

        if self.scanning {
            self.show_scanning_ui(ctx);
        } else {
            self.process_watch_events(ctx);
            self.show_treemap_ui(ctx);
            self.show_rename_dialog(ctx);
            show_settings_window(ctx, &mut self.settings);
            self.ensure_watching(ctx);
        }
    }
}

/// Spawn a new instance of the app as a separate process.
fn spawn_new_instance() {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };

    // Inside a macOS bundle, go through LaunchServices so the new instance is
    // launched as an app (required in the App Sandbox) rather than as a child.
    #[cfg(target_os = "macos")]
    if let Some(bundle) = enclosing_app_bundle(&exe) {
        if std::process::Command::new("open")
            .arg("-n")
            .arg(bundle)
            .spawn()
            .is_ok()
        {
            return;
        }
    }

    let _ = std::process::Command::new(exe).spawn();
}

/// The `.app` bundle containing `exe`, if it lives at `X.app/Contents/MacOS/<bin>`.
#[cfg(any(target_os = "macos", test))]
fn enclosing_app_bundle(exe: &Path) -> Option<&Path> {
    let macos_dir = exe.parent()?;
    let contents_dir = macos_dir.parent()?;
    let bundle = contents_dir.parent()?;
    let is_bundle = macos_dir.file_name()? == "MacOS"
        && contents_dir.file_name()? == "Contents"
        && bundle.extension()? == "app";
    is_bundle.then_some(bundle)
}

/// Move a file or directory to the trash.
fn move_to_trash(path: &Path) -> Result<(), trash::Error> {
    // The default macOS method scripts Finder with Apple Events, which the App
    // Sandbox blocks. NSFileManager works sandboxed (at the cost of Finder's
    // "Put Back" menu item).
    #[cfg(all(target_os = "macos", feature = "app-store"))]
    {
        use trash::macos::{DeleteMethod, TrashContextExtMacos};
        let mut ctx = trash::TrashContext::new();
        ctx.set_delete_method(DeleteMethod::NsFileManager);
        ctx.delete(path)
    }
    #[cfg(not(all(target_os = "macos", feature = "app-store")))]
    {
        trash::delete(path)
    }
}

/// Insert `child` among `children` (sorted by size, largest first).
fn insert_by_size(children: &mut Vec<FileNode>, child: FileNode) {
    let pos = children
        .iter()
        .position(|c| c.size < child.size)
        .unwrap_or(children.len());
    children.insert(pos, child);
}

/// Replace (or with `None`, remove) the child `name` of the directory at
/// `parents` below `node`, adjusting the size of `node` and every directory
/// in between and keeping each level sorted. Returns the child's old and new
/// sizes, or `None` if `parents` isn't in the tree.
fn replace_child(
    node: &mut FileNode,
    parents: &[String],
    name: &str,
    new: Option<FileNode>,
) -> Option<(u64, u64)> {
    let (old_size, new_size) = match parents.split_first() {
        Some((first, rest)) => {
            let idx = node
                .children
                .iter()
                .position(|c| c.is_dir && &c.name == first)?;
            let sizes = replace_child(&mut node.children[idx], rest, name, new)?;
            if sizes.0 != sizes.1 {
                let child = node.children.remove(idx);
                insert_by_size(&mut node.children, child);
            }
            sizes
        }
        None => {
            let old = node
                .children
                .iter()
                .position(|c| c.name == name)
                .map_or(0, |idx| node.children.remove(idx).size);
            let new_size = new.as_ref().map_or(0, |n| n.size);
            if let Some(new) = new {
                insert_by_size(&mut node.children, new);
            }
            (old, new_size)
        }
    };
    node.size = node.size.saturating_sub(old_size).saturating_add(new_size);
    Some((old_size, new_size))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Scan `dir` synchronously into a fresh app, as `update` would.
    fn app_for(dir: &Path, ctx: &egui::Context) -> TreemapApp {
        let mut app = TreemapApp::new(
            dir.to_path_buf(),
            HashSet::new(),
            SettingsState::default(),
            ctx,
        );
        while !*app.scan_progress.done.lock().unwrap() {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        app.root = app.scan_progress.result.lock().unwrap().take();
        app.scanning = false;
        app
    }

    fn names(app: &TreemapApp) -> Vec<String> {
        let mut v: Vec<String> = app
            .current_node()
            .unwrap()
            .children
            .iter()
            .map(|c| c.name.clone())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn reconcile_tracks_create_rename_remove_and_new_dirs() {
        let root = std::env::temp_dir().join(format!("alocir-watch-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("sub/a.bin"), vec![1u8; 100_000]).unwrap();
        // Sizes are on-disk usage, so derive expectations from the files.
        let usage = |p: &Path| alocir_shared::scanner::disk_usage(&std::fs::metadata(p).unwrap());
        let ctx = egui::Context::default();
        let mut app = app_for(&root, &ctx);
        app.nav_stack = vec![0]; // into "sub"
        let sub = root.join("sub");
        let total = |app: &TreemapApp| app.root.as_ref().unwrap().size;
        let a = usage(&sub.join("a.bin"));

        // New file
        std::fs::write(sub.join("b.bin"), vec![1u8; 50_000]).unwrap();
        let b = usage(&sub.join("b.bin"));
        app.reconcile_path(&sub.join("b.bin"), &ctx);
        assert_eq!(names(&app), ["a.bin", "b.bin"]);
        assert_eq!(total(&app), a + b);

        // Rename: both paths reported, in either order
        std::fs::rename(sub.join("b.bin"), sub.join("c.bin")).unwrap();
        app.reconcile_path(&sub.join("c.bin"), &ctx);
        app.reconcile_path(&sub.join("b.bin"), &ctx);
        assert_eq!(names(&app), ["a.bin", "c.bin"]);
        assert_eq!(total(&app), a + b);

        // Grown file
        std::fs::write(sub.join("c.bin"), vec![1u8; 500_000]).unwrap();
        let c = usage(&sub.join("c.bin"));
        app.reconcile_path(&sub.join("c.bin"), &ctx);
        assert_eq!(total(&app), a + c);
        assert_eq!(app.current_node().unwrap().children[0].name, "c.bin");

        // Removed file
        std::fs::remove_file(sub.join("a.bin")).unwrap();
        app.reconcile_path(&sub.join("a.bin"), &ctx);
        assert_eq!(names(&app), ["c.bin"]);
        assert_eq!(total(&app), c);

        // A directory with nested contents appears: placeholder, then full size
        std::fs::create_dir_all(sub.join("new/deep")).unwrap();
        std::fs::write(sub.join("new/deep/x.bin"), vec![1u8; 1_000_000]).unwrap();
        let x = usage(&sub.join("new/deep/x.bin"));
        app.reconcile_path(&sub.join("new"), &ctx);
        assert_eq!(names(&app), ["c.bin", "new"]);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while total(&app) != c + x && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
            app.process_watch_events(&ctx);
        }
        assert_eq!(total(&app), c + x);
        assert_eq!(app.current_node().unwrap().size, c + x);

        // Events for unchanged or missing paths elsewhere in the tree, or
        // outside the scan root, change nothing.
        app.reconcile_path(&root.join("sub"), &ctx);
        app.reconcile_path(&root.join("elsewhere.bin"), &ctx);
        app.reconcile_path(&root.join("missing/deeper/x.bin"), &ctx);
        app.reconcile_path(&std::env::temp_dir().join("not-ours.bin"), &ctx);
        assert_eq!(names(&app), ["c.bin", "new"]);
        assert_eq!(total(&app), c + x);

        let _ = std::fs::remove_dir_all(&root);
    }

    fn usage(p: &Path) -> u64 {
        alocir_shared::scanner::disk_usage(&std::fs::metadata(p).unwrap())
    }

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("alocir-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        root
    }

    fn node<'a>(app: &'a TreemapApp, path: &[&str]) -> &'a FileNode {
        let names: Vec<String> = path.iter().map(|s| s.to_string()).collect();
        app.dir_at(&names).unwrap()
    }

    /// Poll background results until `done` holds, or panic after 5s.
    fn wait_for(app: &mut TreemapApp, ctx: &egui::Context, done: impl Fn(&TreemapApp) -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !done(app) {
            assert!(std::time::Instant::now() < deadline, "timed out");
            std::thread::sleep(std::time::Duration::from_millis(5));
            app.process_watch_events(ctx);
        }
    }

    #[test]
    fn reconcile_two_levels_below_current_updates_all_ancestors() {
        let root = temp_root("deep-test");
        std::fs::create_dir_all(root.join("a/b")).unwrap();
        std::fs::write(root.join("top.bin"), vec![1u8; 10_000]).unwrap();
        std::fs::write(root.join("a/b/f.bin"), vec![1u8; 20_000]).unwrap();
        let ctx = egui::Context::default();
        let mut app = app_for(&root, &ctx);
        let top = usage(&root.join("top.bin"));
        let f = usage(&root.join("a/b/f.bin"));
        assert!(app.nav_stack.is_empty()); // viewing the root

        // New file two levels below the current directory.
        std::fs::write(root.join("a/b/g.bin"), vec![1u8; 300_000]).unwrap();
        let g = usage(&root.join("a/b/g.bin"));
        app.reconcile_path(&root.join("a/b/g.bin"), &ctx);
        assert_eq!(node(&app, &["a", "b"]).size, f + g);
        assert_eq!(node(&app, &["a"]).size, f + g);
        assert_eq!(node(&app, &[]).size, top + f + g);
        // The root's children were re-sorted: "a" is now the largest.
        assert_eq!(node(&app, &[]).children[0].name, "a");

        // Removal two levels down.
        std::fs::remove_file(root.join("a/b/f.bin")).unwrap();
        app.reconcile_path(&root.join("a/b/f.bin"), &ctx);
        assert_eq!(node(&app, &["a", "b"]).size, g);
        assert_eq!(node(&app, &[]).size, top + g);

        // A file inside a directory the tree doesn't know: the highest
        // missing directory is reconciled (and scanned) instead.
        std::fs::create_dir_all(root.join("a/n1/n2")).unwrap();
        std::fs::write(root.join("a/n1/n2/h.bin"), vec![1u8; 40_000]).unwrap();
        let h = usage(&root.join("a/n1/n2/h.bin"));
        app.reconcile_path(&root.join("a/n1/n2/h.bin"), &ctx);
        wait_for(&mut app, &ctx, |app| {
            app.root.as_ref().unwrap().size == top + g + h
        });
        assert_eq!(node(&app, &["a", "n1", "n2"]).size, h);
        assert_eq!(node(&app, &["a"]).size, g + h);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn reconcile_keeps_nav_stack_on_the_same_directory() {
        let root = temp_root("nav-test");
        for d in ["big", "small/inner"] {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
        std::fs::write(root.join("big/x.bin"), vec![1u8; 500_000]).unwrap();
        std::fs::write(root.join("small/inner/y.bin"), vec![1u8; 10_000]).unwrap();
        let ctx = egui::Context::default();
        let mut app = app_for(&root, &ctx);
        // Navigate into small/inner (small is at index 1, after big).
        app.nav_stack = nav_to(&app, &["small", "inner"]);
        assert_eq!(app.nav_stack[0], 1);
        assert_eq!(app.current_dir_path(), root.join("small/inner"));

        // small/inner grows past big, so "small" moves to index 0.
        std::fs::write(root.join("small/inner/z.bin"), vec![1u8; 2_000_000]).unwrap();
        app.reconcile_path(&root.join("small/inner/z.bin"), &ctx);
        assert_eq!(app.nav_stack[0], 0);
        assert_eq!(app.current_dir_path(), root.join("small/inner"));
        assert_eq!(names(&app), ["y.bin", "z.bin"]);

        // A change under a sibling directory moves it back.
        std::fs::write(root.join("big/w.bin"), vec![1u8; 4_000_000]).unwrap();
        app.reconcile_path(&root.join("big/w.bin"), &ctx);
        assert_eq!(app.nav_stack[0], 1);
        assert_eq!(app.current_dir_path(), root.join("small/inner"));

        // If the current directory is deleted, navigation falls back to the
        // deepest directory that still exists.
        std::fs::remove_dir_all(root.join("small/inner")).unwrap();
        app.reconcile_path(&root.join("small/inner"), &ctx);
        assert_eq!(app.current_dir_path(), root.join("small"));
        assert!(app.current_node().is_some());

        let _ = std::fs::remove_dir_all(&root);
    }

    fn nav_to(app: &TreemapApp, names: &[&str]) -> Vec<usize> {
        let names: Vec<String> = names.iter().map(|s| s.to_string()).collect();
        TreemapApp::restore_nav(app.root.as_ref().unwrap(), &names)
    }

    #[test]
    fn rescan_flag_rescans_the_affected_directory() {
        let root = temp_root("rescan-test");
        std::fs::create_dir_all(root.join("d/e")).unwrap();
        std::fs::write(root.join("d/e/a.bin"), vec![1u8; 10_000]).unwrap();
        let ctx = egui::Context::default();
        let mut app = app_for(&root, &ctx);
        let a = usage(&root.join("d/e/a.bin"));

        // Changes the watcher never reported individually.
        std::fs::write(root.join("d/e/b.bin"), vec![1u8; 70_000]).unwrap();
        std::fs::create_dir_all(root.join("d/e/new")).unwrap();
        std::fs::write(root.join("d/e/new/c.bin"), vec![1u8; 30_000]).unwrap();
        std::fs::remove_file(root.join("d/e/a.bin")).unwrap();
        let (b, c) = (
            usage(&root.join("d/e/b.bin")),
            usage(&root.join("d/e/new/c.bin")),
        );
        assert_eq!(app.root.as_ref().unwrap().size, a);

        // Feed a rescan-flagged event through a fake watcher channel.
        let (tx, rx) = mpsc::channel();
        app.watch_rx = Some(rx);
        let rescan = |paths: Vec<PathBuf>| {
            let mut event =
                notify::Event::new(notify::EventKind::Other).set_flag(notify::event::Flag::Rescan);
            event.paths = paths;
            event
        };
        tx.send(Ok(rescan(vec![root.join("d/e")]))).unwrap();
        app.process_watch_events(&ctx);
        assert!(app.pending_scans.contains_key(&root.join("d/e")));
        wait_for(&mut app, &ctx, |app| {
            app.root.as_ref().unwrap().size == b + c
        });
        assert_eq!(node(&app, &["d", "e", "new"]).size, c);
        assert_eq!(node(&app, &["d"]).size, b + c);
        assert!(app.pending_scans.is_empty());

        // A rescan with no path re-scans the whole tree.
        std::fs::write(root.join("top.bin"), vec![1u8; 5_000]).unwrap();
        let top = usage(&root.join("top.bin"));
        tx.send(Ok(rescan(Vec::new()))).unwrap();
        app.process_watch_events(&ctx);
        assert!(app.pending_scans.contains_key(&root));
        wait_for(&mut app, &ctx, |app| {
            app.root.as_ref().unwrap().size == b + c + top
        });

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn duplicate_paths_in_a_batch_are_reconciled_once() {
        let root = temp_root("dedup-test");
        std::fs::create_dir_all(root.join("s")).unwrap();
        let ctx = egui::Context::default();
        let mut app = app_for(&root, &ctx);
        std::fs::create_dir_all(root.join("s/newdir")).unwrap();
        std::fs::write(root.join("s/newdir/f.bin"), vec![1u8; 10_000]).unwrap();
        let f = usage(&root.join("s/newdir/f.bin"));

        let (tx, rx) = mpsc::channel();
        app.watch_rx = Some(rx);
        for _ in 0..1000 {
            let event =
                notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::Any))
                    .add_path(root.join("s/newdir"));
            tx.send(Ok(event)).unwrap();
        }
        app.process_watch_events(&ctx);
        // One placeholder and one background scan, not a thousand.
        assert_eq!(app.pending_scans.len(), 1);
        assert!(!app.pending_scans[&root.join("s/newdir")]);
        wait_for(&mut app, &ctx, |app| app.root.as_ref().unwrap().size == f);

        let _ = std::fs::remove_dir_all(&root);
    }

    /// End to end with the platform's real recursive watcher: changes two
    /// levels below the scan root show up without navigating there.
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    #[test]
    fn real_recursive_watcher_tracks_deep_changes() {
        let root = temp_root("e2e-watch-test");
        std::fs::create_dir_all(root.join("l1/l2")).unwrap();
        let ctx = egui::Context::default();
        let mut app = app_for(&root, &ctx);
        assert!(app.settings.watch_subfolders);
        app.ensure_watching(&ctx);
        assert_eq!(app.watched, Some((root.clone(), RecursiveMode::Recursive)));
        assert!(app._watcher.is_some());
        // FSEvents may deliver events from just before the stream started.
        std::thread::sleep(std::time::Duration::from_millis(300));

        let deep = root.join("l1/l2");
        let has = |app: &TreemapApp, name: &str| {
            node(app, &["l1", "l2"])
                .children
                .iter()
                .any(|c| c.name == name)
        };
        let wait = |app: &mut TreemapApp, what: &str, done: &dyn Fn(&TreemapApp) -> bool| {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
            while !done(app) {
                assert!(
                    std::time::Instant::now() < deadline,
                    "timed out waiting for {what}"
                );
                std::thread::sleep(std::time::Duration::from_millis(20));
                app.process_watch_events(&ctx);
            }
        };

        std::fs::write(deep.join("a.bin"), vec![1u8; 100_000]).unwrap();
        let a = usage(&deep.join("a.bin"));
        wait(&mut app, "create", &|app| has(app, "a.bin"));
        wait(&mut app, "create size", &|app| {
            app.root.as_ref().unwrap().size == a
        });
        assert_eq!(node(&app, &["l1"]).size, a);

        std::fs::rename(deep.join("a.bin"), deep.join("b.bin")).unwrap();
        wait(&mut app, "rename", &|app| {
            has(app, "b.bin") && !has(app, "a.bin")
        });
        assert_eq!(app.root.as_ref().unwrap().size, a);

        std::fs::remove_file(deep.join("b.bin")).unwrap();
        wait(&mut app, "delete", &|app| !has(app, "b.bin"));
        assert_eq!(app.root.as_ref().unwrap().size, 0);

        // Navigating doesn't replace the recursive watcher.
        app.nav_stack = vec![0];
        app.ensure_watching(&ctx);
        assert_eq!(app.watched, Some((root.clone(), RecursiveMode::Recursive)));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn toggling_watch_subfolders_switches_modes() {
        let root = temp_root("toggle-test");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        let ctx = egui::Context::default();
        let mut app = app_for(&root, &ctx);
        app.nav_stack = vec![0];

        app.settings.watch_subfolders = false;
        app.ensure_watching(&ctx);
        assert_eq!(
            app.watched,
            Some((root.join("sub"), RecursiveMode::NonRecursive))
        );

        app.settings.watch_subfolders = true;
        app.ensure_watching(&ctx);
        assert_eq!(app.watched, Some((root.clone(), RecursiveMode::Recursive)));

        // A failed recursive watch falls back and says why.
        let err = notify::Error::new(notify::ErrorKind::MaxFilesWatch);
        app.fall_back_to_non_recursive(&err, &ctx);
        assert_eq!(
            app.watched,
            Some((root.join("sub"), RecursiveMode::NonRecursive))
        );
        assert!(app
            .settings
            .watch_status
            .as_deref()
            .unwrap()
            .contains("limit"));

        // Toggling off and on again retries.
        app.settings.watch_subfolders = false;
        app.ensure_watching(&ctx);
        assert!(app.settings.watch_status.is_none());
        app.settings.watch_subfolders = true;
        app.ensure_watching(&ctx);
        assert_eq!(app.watched, Some((root.clone(), RecursiveMode::Recursive)));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn finds_enclosing_app_bundle() {
        assert_eq!(
            enclosing_app_bundle(Path::new("/Applications/Alocir.app/Contents/MacOS/alocir")),
            Some(Path::new("/Applications/Alocir.app"))
        );
    }

    #[test]
    fn no_bundle_for_bare_binary() {
        assert_eq!(
            enclosing_app_bundle(Path::new("/repo/target/release/alocir")),
            None
        );
        assert_eq!(
            enclosing_app_bundle(Path::new("/x/Foo.app/Contents/Helpers/alocir")),
            None
        );
    }
}
