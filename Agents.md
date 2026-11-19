# Alocir

Disk space visualizer in two editions, from this one repository:

- **Alocir for Mac** (`swift/`, version 2.x): native Swift/SwiftUI app for macOS 26 and later, shipped through the Mac App Store.
- **Alocir for Windows, Linux and older Macs** (`crates/`, version 1.x): Rust and egui, shipped on GitHub Releases, including a notarized macOS build for Macs that can't run macOS 26. Keep that macOS build.

The two have separate version numbers. Most of this file is about the Rust workspace; the Mac edition is under "Native macOS app (2.0)" below. The public pages are on opensf.foundation (`~/Projects/opensf`: `src/pages/products/alocir/`, and the Alocir section of `src/pages/privacy.astro`); keep them, `README.md` and `PRIVACY.md` in step when either edition changes what it stores or does.

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
| `crates/alocir/src/app/views.rs` | What `TreemapApp` draws: scanning screen, toolbar (breadcrumbs, search field), nested treemap (one hit-tested area, painted from the cached layout), status bar, rename dialog, keyboard navigation |
| `crates/alocir/src/app/inspector.rs` | The inspector panel: selected item, breakdown by kind (the colour legend), largest files or search results |
| `crates/alocir/src/store.rs` | Settings, window size and recent folders, saved as small text files in the platform's settings folder |
| `crates/alocir/src/ui.rs` | Small widgets shared by the start screen and the views |
| `crates/shared/src/scanner.rs` | `FileNode` tree, parallel recursive scan (Rayon), `ScanProgress`, `disk_usage` |
| `crates/shared/src/treemap.rs` | Squarified layout (`squarify`), the nested layout (`layout_nested`, ported from the Mac edition's `Treemap.swift`), hit testing and arrow-key moves |
| `crates/shared/src/kind.rs` | `FileKind` from a file's extension (same table as `FileKind.swift`), stored in each `FileNode` |
| `crates/shared/src/search.rs` | Search query syntax (same as `Search.swift`) and the marking search over the tree |
| `crates/shared/src/summary.rs` | Folder summary for the inspector and each folder's dominant kind |
| `crates/shared/src/theme.rs` | `ColorScheme` (6 themes), the egui `Style` for each, tile colours and label contrast |
| `crates/shared/src/settings.rs` | Settings window: colour scheme picker, nesting depth, labels, inspector, recent folders, Linux-only "Watch subfolders" option |
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
- **Hot path**: the treemap is painted every frame, and a folder can have 50,000+ entries. The nested layout and folder tints are cached (`LayoutCache` in `app.rs`) and rebuilt only when the tree's `version`, the folder, the map's size or the depth changes; bump `version` whenever the tree changes. Build labels, tooltips and paths only for tiles that are drawn or hovered, and check `cargo bench -p alocir-shared --bench core` before and after changing `scanner.rs`, `treemap.rs`, `search.rs`, `summary.rs` or the tile loop.
- **Same behaviour in both editions**: file kinds, the search syntax, the nested layout and the folder summary are ports of the Swift engine. Change them in both, and keep their tests in step.
- **Live filesystem watching**: on macOS and Windows the scan root is watched recursively (FSEvents and ReadDirectoryChangesW are cheap). On Linux only the current folder is watched, unless the user enables "Watch subfolders" (inotify uses one watch per folder); if that hits the watch limit the app falls back and says why. Events aren't trusted for their kind: `reconcile_path` compares each path with what's on disk. Folders that appear are scanned on a background thread.
- **Deferred actions**: context menu actions are collected into a `RefCell<Option<DeferredAction>>` and run after the UI pass, to avoid borrowing conflicts.
- **Platform conditionals**: `file_ops.rs` and `context_menu.rs` use `cfg!(target_os = ...)` for macOS/Windows/Linux behaviour.
- **No third-party names**: theme names, UI text and store text stay generic. Don't name other products, operating systems or apps (App Review flags it as an intellectual-property issue).
- **Mac App Store build (obsolete)**: the `app-store` Cargo feature hides what the App Sandbox blocks ("Open Terminal Here", "Home" and "Startup Disk") and trashes through `NSFileManager`. It built the 1.0 store package; the store now gets the Swift app. See `docs/mac-app-store.md`.
- **No private APIs in the store app**: App Review rejects binaries that import private functions or name undocumented selectors (the Rust 1.0.0 was rejected for one in winit). The store gets the Swift app, which `scripts/check-private-apis.sh` checks on every build. The Rust app uses upstream winit, which has such calls; that's fine outside the App Store, so `build-macos.sh` only runs the check for `--app-store` builds (which no longer pass).

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
cargo run -p alocir -- --theme daylight ~/Downloads   # Skip the start screen
cargo test --workspace                     # Run tests
cargo bench -p alocir-shared               # Benchmarks (criterion)
cargo fmt --all                            # Format (CI fails on unformatted code)
cargo clippy --workspace --all-targets -- -D warnings                 # Lint, as CI does
cargo clippy -p alocir --features app-store --all-targets -- -D warnings  # Lint the store build
./scripts/build-macos.sh --universal       # macOS .app bundle (see the script header for signing options)
./scripts/check-private-apis.sh target/release/Alocir.app  # Scan a macOS build for private APIs, as App Review does
```

Linux requires system dependencies:
```bash
sudo apt-get install -y libxcb-render0-dev libxcb-shape0-dev libxcb-xfixes0-dev \
  libxkbcommon-dev libgtk-3-dev
```

## Native macOS app (2.0, `swift/`)

From 2.0.0 the Mac App Store app is a native Swift/SwiftUI rewrite with Liquid Glass. It runs on macOS 26 and later (Apple Silicon and Intel; 26 is the last macOS for Intel Macs) and is built with the macOS 27 SDK, so anything newer than macOS 26 needs an `if #available` check; the compiler enforces this. The plan is `docs/swift-rewrite.md`. The Rust app in `crates/` keeps shipping for Windows, Linux and Macs older than macOS 26; don't delete or restructure `crates/` or the Rust CI jobs.

| Path | Purpose |
|------|---------|
| `swift/Package.swift` | `AlocirCore` library, `alocir-scan` command, tests (Swift 6, strict concurrency, no package dependencies) |
| `swift/Sources/AlocirCore/` | `DirectoryReader` (`getattrlistbulk`, `readdir` fallback), `DiskScanner`, `FileNode`, `LiveTree` + `FSEventsWatcher` (live reconciling, ported from `app.rs`), `Treemap` (nested squarify, hit testing, arrow-key moves), `Search`, `FolderSummary`, `Formatting` |
| `swift/Alocir.xcodeproj` | The app target. `App/` is a synchronized folder: every Swift file in it compiles |
| `swift/App/Model/` | `Session` (one per window: phase, navigation, file actions), `AppSettings`, `RecentFolders` (security-scoped bookmarks), `Palette` |
| `swift/App/Views/` | Start, scanning, map (`TreemapCanvas` draws with one `Canvas`), inspector, settings, context menu and rename sheet |
| `swift/App/Support/` | `DemoData` and `ScreenshotMode` (`Alocir -screenshot <scene>`, used by CI) |
| `swift/scripts/` | `ci.sh`, `compare-totals.sh`, `bench.sh`, `screenshots.sh`, `archive.sh` |

Rules that carry over: sizes are disk usage, each directory and hard-linked file is counted once, truncate by `Character`, no third-party names, no private APIs, no network. Before changing the scanner or layout, run `swift/scripts/bench.sh ~` and compare with the Rust scanner.

```bash
cd swift
swift build -c release && swift test         # engine and tests
./scripts/compare-totals.sh                  # Swift and Rust totals must match
./scripts/bench.sh --runs 5 ~                # Swift vs Rust timings and memory
open Alocir.xcodeproj                         # the app
BUILD_NUMBER=32 ./scripts/archive.sh          # store package, signed, not uploaded
```

## CI/CD

`.github/workflows/ci.yml`:

- **lint** (Linux): `cargo fmt --all --check` and clippy with `-D warnings`.
- **build**: builds and tests on Linux x86_64, Windows x86_64 and macOS, and builds a universal macOS `.app`. On pushes to `main` with signing secrets set, the app is signed with Developer ID and notarized; otherwise it is ad-hoc signed.
- **release**: on pushes to `main`, creates a GitHub Release tagged with the version from `crates/alocir/Cargo.toml`, with zip artifacts.
- **swift** (`xcode-27` runner): `swift/scripts/ci.sh` builds and tests the Swift engine, checks its totals against the Rust scanner, builds the universal app with the macOS 27 SDK (failing without both arm64 and x86_64) and runs the private-API check; then `screenshots.sh` captures every screen with demo data as the `screenshots` artifact.
- **macos-26** (`macos-26` and `macos-26-intel` runners): runs the engine tests and launches every screen of the app built by the **swift** job, on the oldest supported macOS, on both architectures.
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
- Alocir for Mac 2.0.0 in App Review; once approved, replace the "coming soon" labels on opensf.foundation with the App Store link
- Bug fixes for filesystem watcher edge cases

### Next
- The two editions have the same features (nested map, search, inspector, keyboard navigation, settings and recent folders). Keep them in step.
- Scan progress bar (percentage-based)

### Future
- Duplicate file detection
- Disk usage trends over time
- Export reports (CSV / HTML)
- Custom color scheme editor
