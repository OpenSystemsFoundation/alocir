# Alocir

Cross-platform disk space visualizer built with Rust and egui.

## Architecture

A Cargo workspace with three crates:

| Crate | Purpose |
|-------|---------|
| `crates/alocir` | The app that ships (binary `alocir`) |
| `crates/shared` (`alocir-shared`) | Scanner, treemap layout, themes, settings, context menu, file operations; also has the benchmarks |
| `crates/explorer` (`alocir-explorer`) | A separate file-explorer experiment. Not shipped or released; keep it compiling. |

`crates/alocir` is a two-phase state machine (`AlocirApp` in `main.rs`):

1. **Start screen**: choose a folder (native dialog), drop one on the window, or scan the home folder. A folder given on the command line (`alocir [--theme NAME] [FOLDER]`) skips this screen.
2. **Scan + treemap** (`TreemapApp`): parallel scan with a progress screen, then an interactive squarified treemap with live filesystem updates.

### Source files

| File | Purpose |
|------|---------|
| `crates/alocir/src/main.rs` | Entry point, command-line parsing, `AlocirApp` state machine, start screen |
| `crates/alocir/src/app.rs` | `TreemapApp` state: navigation, filesystem watching and reconciling the in-memory tree, trash, new instance |
| `crates/alocir/src/app/views.rs` | What `TreemapApp` draws: scanning screen, toolbar and breadcrumbs, treemap tiles, status bar, rename dialog, keyboard shortcuts |
| `crates/alocir/src/ui.rs` | Small widgets shared by the start screen and the views |
| `crates/shared/src/scanner.rs` | `FileNode` tree, parallel recursive scan (Rayon), `ScanProgress`, `disk_usage` |
| `crates/shared/src/treemap.rs` | Squarified layout (`squarify`) and `layout_visible`, which keeps only drawable tiles |
| `crates/shared/src/theme.rs` | `ColorScheme` (6 themes), the egui `Style` for each, tile colours and label contrast |
| `crates/shared/src/settings.rs` | Settings window: colour scheme picker, Linux-only "Watch subfolders" option |
| `crates/shared/src/context_menu.rs` | Right-click menu (open, reveal, copy path, rename, move to trash, open terminal) |
| `crates/shared/src/file_ops.rs` | Platform-specific commands (`open`, `xdg-open`, `cmd /C start`, etc.) |
| `crates/shared/src/text.rs` | Character-safe truncation, number and duration formatting |
| `crates/shared/src/glyphs.rs` | Icon glyphs, each checked to exist in egui's bundled fonts |
| `crates/shared/src/icon.rs` | Window icon generation |
| `crates/shared/benches/core.rs` | Criterion benchmarks: treemap layout, per-frame tile work, scanning |

### Key patterns

- **Sizes are disk usage**: `scanner::disk_usage` returns allocated blocks (`st_blocks * 512`) on Unix and file length on Windows. Hard-linked files are counted once per scan.
- **Each directory is counted once**: the scanner records every directory's `(device, inode)` and skips one reached again through another path (macOS firmlinks such as `/Users` → `/System/Volumes/Data/Users`, Linux bind mounts). On macOS, `/System/Volumes/Data` is scanned last when a scan includes it, so data is counted under the familiar paths and only what is unique to that volume stays under it. Check totals against `df` with `cargo run --release -p alocir-shared --example scan_total -- /`.
- **Never slice strings by byte index**: file names can contain any Unicode. Use `text::truncate_end` / `truncate_start`.
- **Hot path**: the treemap is laid out and painted every frame, and a folder can have 50,000+ entries. Build labels, tooltips and paths only for tiles that are drawn or hovered, and check `cargo bench -p alocir-shared` before and after changing `scanner.rs`, `treemap.rs` or the tile loop.
- **Live filesystem watching**: on macOS and Windows the scan root is watched recursively (FSEvents and ReadDirectoryChangesW are cheap). On Linux only the current folder is watched, unless the user enables "Watch subfolders" (inotify uses one watch per folder); if that hits the watch limit the app falls back and says why. Events aren't trusted for their kind: `reconcile_path` compares each path with what's on disk. Folders that appear are scanned on a background thread.
- **Deferred actions**: context menu actions are collected into a `RefCell<Option<DeferredAction>>` and run after the UI pass, to avoid borrowing conflicts.
- **Platform conditionals**: `file_ops.rs` and `context_menu.rs` use `cfg!(target_os = ...)` for macOS/Windows/Linux behaviour.
- **No third-party names**: theme names, UI text and store text stay generic. Don't name other products, operating systems or apps (App Review flags it as an intellectual-property issue).
- **Mac App Store build**: the `app-store` Cargo feature hides what the App Sandbox blocks ("Open Terminal Here", "Scan Home Folder") and trashes through `NSFileManager`. See `docs/mac-app-store.md`.

### Dependencies

| Crate | Purpose |
|-------|---------|
| eframe 0.31 | GUI framework (egui) |
| rayon 1 | Parallel directory scanning |
| rfd 0.15 | Native file dialogs |
| trash 5 | Cross-platform trash/recycle bin |
| notify 8 | Filesystem watching |
| criterion 0.5 (dev) | Benchmarks |

## Build

```bash
cargo run --release -p alocir              # Build and run
cargo run -p alocir -- --theme mac ~/Downloads   # Skip the start screen
cargo test --workspace                     # Run tests
cargo bench -p alocir-shared               # Benchmarks (criterion)
cargo fmt --all                            # Format (CI fails on unformatted code)
cargo clippy --workspace --all-targets -- -D warnings                 # Lint, as CI does
cargo clippy -p alocir --features app-store --all-targets -- -D warnings  # Lint the store build
./scripts/build-macos.sh --universal       # macOS .app bundle (see the script header for signing options)
```

Linux requires system dependencies:
```bash
sudo apt-get install -y libxcb-render0-dev libxcb-shape0-dev libxcb-xfixes0-dev \
  libxkbcommon-dev libgtk-3-dev
```

## CI/CD

`.github/workflows/ci.yml`:

- **lint** (Linux): `cargo fmt --all --check` and clippy with `-D warnings`.
- **build**: builds and tests on Linux x86_64, Windows x86_64 and macOS, and builds a universal macOS `.app`. On pushes to `main` with signing secrets set, the app is signed with Developer ID and notarized; otherwise it is ad-hoc signed.
- **release**: on pushes to `main`, creates a GitHub Release tagged with the version from `crates/alocir/Cargo.toml`, with zip artifacts.
- **app-store**: manual runs only (`workflow_dispatch`). Builds the sandboxed store package and uploads it to App Store Connect. Skipped when its secrets are missing.

Secrets: `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY` and `APPLE_API_KEY_P8`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` for notarized releases; the `MAS_*` secrets listed in `docs/mac-app-store.md` for the store job. Bump the version in `crates/alocir/Cargo.toml` before a release, or the release with that tag is updated in place.

## AI-assisted development

This project is developed with the assistance of [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

### Guidelines

- Always review generated code before merging
- Verify tests pass on all target platforms (Windows, Linux, macOS)
- Keep the human in the loop for architectural decisions

## Roadmap

### Now
- Stabilize cross-platform builds and release packaging
- Bug fixes for filesystem watcher edge cases

### Next
- Mac App Store release (see `docs/mac-app-store.md`)
- Scan progress bar (percentage-based)
- Persistent settings (remember last color scheme, window size)
- Keyboard navigation between treemap tiles (shortcuts for up and rescan exist)
- Search / filter files by name or extension

### Future
- Nested treemap: draw subfolders' contents inside their tiles instead of one level at a time
- Duplicate file detection
- Disk usage trends over time
- Export reports (CSV / HTML)
- Custom color scheme editor
