<p align="center">
  <img src="assets/logo.svg" alt="Alocir" width="128" height="128">
</p>

<h1 align="center">Alocir</h1>

<p align="center">
  A disk space visualizer: a native app for Mac, and a Rust app for Windows, Linux and older Macs.
</p>

<p align="center">
  <a href="https://github.com/OpenSystemsFoundation/alocir/actions/workflows/ci.yml">
    <img src="https://github.com/OpenSystemsFoundation/alocir/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
</p>

---

Alocir scans a folder in parallel and draws what's in it as a treemap: every
file and folder is a rectangle sized by the space it takes on disk, so the
biggest items stand out. It comes in two editions, built from this one
repository:

| | Alocir for Mac | Alocir for Windows, Linux and older Macs |
|---|---|---|
| Source | [`swift/`](swift/) (Swift, SwiftUI) | [`crates/`](crates/) (Rust, egui) |
| Runs on | macOS 26 and later, Apple Silicon and Intel | 64-bit Windows and Linux; macOS 11 to 15 |
| Get it | Mac App Store (coming soon) | [GitHub Releases](https://github.com/OpenSystemsFoundation/alocir/releases) |
| Version | 2.x | 1.x |

On a Mac with macOS 26 or later, use Alocir for Mac. The Rust edition's
macOS download stays available for Macs that can't run macOS 26. Both
editions count disk space the same way, and CI checks that their scanners
report the same totals.

The two editions have separate version numbers. GitHub Releases are tagged
with the Rust edition's version (`crates/alocir/Cargo.toml`); the Mac edition's
version is `MARKETING_VERSION` in `swift/Alocir.xcodeproj` and is released
through the App Store.

## Features

Both editions:

- **Nested treemap** — subfolders drawn inside their folders, one to eight levels deep, coloured by kind of file
- **Real disk usage** — Sizes are the space files occupy on disk (allocated blocks), so sparse files don't inflate totals, hard-linked files are counted once, and a folder reachable through two paths (such as macOS's `/Users` and `/System/Volumes/Data/Users`) is counted once when you scan the whole disk. On Windows, sizes are file lengths.
- **Parallel scanning** on every core
- **Live updates** — Files created, changed, renamed, moved or deleted while you look are reflected without a rescan
- **Search** by name, extension (`.mov`) or size (`>100mb`), with matches highlighted on the map
- **Inspector** with the selected item's size, what kinds of files fill a folder, and its largest files
- **Keyboard navigation** between tiles, and a quick preview (Quick Look on the Mac)
- **File operations** from the right-click menu: open, show in the file manager, copy path, rename, move to trash
- **Recent folders** and settings that are remembered

Alocir for Mac also has window tabs, the system's glass design, and light,
dark and classic glossy colours.

Alocir for Windows, Linux and older Macs also has:

- **6 color schemes** — Dark Mode, Purple Dreams, Daylight, Classic, Sky and Phosphor; each styles the whole interface, not just the tiles
- **Open a terminal** in any folder from the right-click menu
- A command line: `alocir [--theme NAME] [FOLDER]`
- On Linux, an optional **Watch subfolders** setting (inotify uses one watch per folder, so by default only the folder you're viewing is watched)

## Alocir for Mac

### Install

Alocir for Mac is coming soon to the Mac App Store.

### Build from source

Needs Xcode 27 (the macOS 27 SDK); the app runs on macOS 26 and later.

```bash
cd swift
swift build -c release && swift test   # engine and tests
open Alocir.xcodeproj                  # build and run the app
./scripts/compare-totals.sh            # Swift and Rust totals must match
./scripts/bench.sh --runs 5 ~          # Swift vs Rust timings and memory
```

The engine (`AlocirCore`) is a Swift package with no dependencies; the app uses
only system frameworks. [docs/swift-rewrite.md](docs/swift-rewrite.md) has the
design, and [docs/mac-app-store.md](docs/mac-app-store.md) the store release
process.

### Usage

1. Click **Choose Folder…**, **Home** or **Startup Disk**, pick a recent folder, or drop a folder on the window
2. Click a tile to select it and see it in the inspector; double-click a folder to zoom into it
3. Go back with the path bar, **Delete** or **Cmd+↑**; move between tiles with the arrow keys; **Space** opens Quick Look
4. Search with **Cmd+F**; rescan with **Cmd+R**
5. **Right-click** any tile for file operations

To scan folders macOS protects, grant Alocir **Full Disk Access** in **System
Settings → Privacy & Security**.

## Alocir for Windows, Linux and older Macs

### Download a release

Pre-built binaries are available on the [Releases](https://github.com/OpenSystemsFoundation/alocir/releases) page:

| Platform | Artifact |
|----------|----------|
| Windows (x86_64) | `alocir-windows-x86_64.zip` |
| Linux (x86_64) | `alocir-linux-x86_64.zip` |
| macOS 11 to 15 (Universal — Apple Silicon & Intel) | `alocir-macos-universal.zip` |

The macOS app is signed with a Developer ID and notarized by Apple, so it opens
like any other downloaded app. Releases up to v0.2.0 were only ad-hoc signed,
and Gatekeeper blocks them on first launch. To open one of those:
**right-click** `Alocir.app` → **Open** → **Open**, or run
`xattr -cr /Applications/Alocir.app` in Terminal.

### Build from source

Needs [Rust](https://www.rust-lang.org/tools/install) 1.87 or later (eframe needs 1.81, `u64::is_multiple_of` needs 1.87).

```bash
cargo run --release -p alocir
```

The compiled binary will be at `target/release/alocir` (or `alocir.exe` on Windows).

```bash
cargo test --workspace
cargo bench -p alocir-shared          # treemap layout, per-frame work, scanning
ALOCIR_BENCH_DIR=~/Downloads cargo bench -p alocir-shared   # also time a real folder
```

Benchmarks use [criterion](https://github.com/bheisler/criterion.rs). Save a
baseline with `-- --save-baseline before` and compare later runs with
`-- --baseline before`.

#### macOS app bundle

```bash
./scripts/build-macos.sh                     # ad-hoc signed, host architecture
./scripts/build-macos.sh --universal         # Apple Silicon + Intel
./scripts/build-macos.sh --universal \
  --sign "Developer ID Application: …" --notarize   # signed and notarized
```

`--notarize` needs `NOTARY_PROFILE` (a profile saved with
`xcrun notarytool store-credentials`) or an App Store Connect API key in
`APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID` and `APPLE_API_ISSUER_ID`. The usage
comment at the top of the script documents every option. Its `--app-store`
mode built the 1.0 store package; from 2.0 the store gets Alocir for Mac
instead.

### Usage

1. Launch the app and **choose a folder**, click **Home** or **Startup Disk**, pick a recent folder, or drop a folder onto the window
2. Click a tile to select it and see it in the inspector; **double-click** a folder to zoom into it
3. Go back with the **Up** button, the **breadcrumb bar**, **Backspace** or the mouse **back** button; **Cmd/Ctrl+↑** goes up, **Cmd/Ctrl+Shift+↑** to the top
4. Move between tiles with the **arrow keys**; **Space** previews, **Return** renames, **Cmd/Ctrl+↓** zooms in, **Cmd/Ctrl+Backspace** moves to the trash
5. Search with **Cmd/Ctrl+F**; show or hide the inspector with **Cmd/Ctrl+Alt+I**
6. **Rescan** with the toolbar button, **Cmd/Ctrl+R** or **F5**
7. Click the **gear icon** for the color scheme, nesting depth, labels and recent folders

Settings and recent folders are kept in `~/Library/Application Support/Alocir`
(macOS), `%APPDATA%\Alocir` (Windows) or `~/.config/alocir` (Linux).

#### Command line

```
alocir [--theme NAME] [FOLDER]
```

`FOLDER` is scanned straight away, skipping the start screen. `--theme` picks
the color scheme: `dark`, `purple`, `daylight`, `classic`, `sky` or `phosphor`.

### Dependencies

| Crate | Purpose |
|-------|---------|
| [eframe](https://github.com/emilk/egui/tree/master/crates/eframe) | GUI framework (egui) |
| [rayon](https://github.com/rayon-rs/rayon) | Parallel iteration |
| [rfd](https://github.com/PolyMeilex/rfd) | Native file dialogs |
| [trash](https://github.com/Byron/trash-rs) | Cross-platform trash/recycle bin |
| [notify](https://github.com/notify-rs/notify) | Filesystem watching for live updates |

## Privacy

Neither edition collects data or has network access. See the [privacy policy](PRIVACY.md).

## License

Apache-2.0
