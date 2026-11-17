<p align="center">
  <img src="assets/logo.svg" alt="Alocir" width="128" height="128">
</p>

<h1 align="center">Alocir</h1>

<p align="center">
  A cross-platform disk space visualizer built with Rust.
</p>

<p align="center">
  <a href="https://github.com/OpenSystemsFoundation/alocir/actions/workflows/ci.yml">
    <img src="https://github.com/OpenSystemsFoundation/alocir/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
</p>

---

## Features

- **Interactive treemap** — Visualize disk usage with a squarified treemap layout
- **Real disk usage** — Sizes are the space files occupy on disk (allocated blocks), so sparse files don't inflate totals, hard-linked files are counted once, and a folder reachable through two paths (such as macOS's `/Users` and `/System/Volumes/Data/Users`) is counted once when you scan the whole disk. On Windows, sizes are file lengths.
- **Parallel scanning** — Fast directory scanning powered by Rayon
- **Live updates** — Files created, changed, renamed, moved or deleted while you look are reflected without a rescan. On macOS and Windows the whole scanned tree is watched; on Linux only the folder you're viewing, unless you enable **Watch subfolders** in Settings (it uses one inotify watch per folder).
- **Drill-down navigation** — Click directories to explore, breadcrumb trail to navigate back, **Rescan** to start over
- **File operations** — Open, reveal in the file manager, copy path, rename, move to trash and open a terminal via the right-click context menu
- **6 color schemes** — Dark Mode, Purple Dreams, Daylight, Classic, Sky and Phosphor; each styles the whole interface, not just the tiles
- **Cross-platform** — Runs on Windows, Linux, and macOS

## Installation

### Download a release

Pre-built binaries are available on the [Releases](https://github.com/OpenSystemsFoundation/alocir/releases) page:

| Platform | Artifact |
|----------|----------|
| Windows (x86_64) | `alocir-windows-x86_64.zip` |
| Linux (x86_64) | `alocir-linux-x86_64.zip` |
| macOS (Universal — Apple Silicon & Intel) | `alocir-macos-universal.zip` |

#### Opening the app on macOS

The macOS app is signed with a Developer ID and notarized by Apple, so it opens
like any other downloaded app.

Releases up to v0.2.0 were only ad-hoc signed, and Gatekeeper blocks them on
first launch. To open one of those: **right-click** `Alocir.app` → **Open** →
**Open**, or run `xattr -cr /Applications/Alocir.app` in Terminal.

To scan folders macOS protects (such as other users' folders or system
locations), grant Alocir **Full Disk Access** in **System Settings → Privacy &
Security**.

### Build from source

#### Prerequisites

- [Rust](https://www.rust-lang.org/tools/install) (1.87+; eframe needs 1.81, `u64::is_multiple_of` needs 1.87)

#### Build and run

```bash
cargo run --release -p alocir
```

The compiled binary will be at `target/release/alocir` (or `alocir.exe` on Windows).

#### Run tests and benchmarks

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
comment at the top of the script documents every option, including the Mac App
Store build (`--app-store`), described in [docs/mac-app-store.md](docs/mac-app-store.md).

#### Native macOS app (2.0)

The Mac App Store version is a native SwiftUI app in `swift/`. It runs on
macOS 26 and later, on Apple Silicon and Intel, and is built with Xcode 27.

```bash
cd swift
swift test                       # engine tests
open Alocir.xcodeproj            # build and run the app
./scripts/bench.sh --runs 5 ~    # compare the Swift and Rust scanners
```

## Usage

1. Launch the app and **choose a folder** (or drop one onto the window, or use **Scan Home Folder**)
2. The treemap fills the window once scanning completes; the status bar shows the hovered item or current path
3. **Click** a folder tile to drill down into it
4. Go back with the **Up** button, the **breadcrumb bar**, **Backspace**/**Escape** or the mouse **back** button
5. **Right-click** any tile for file operations (open, reveal, copy path, rename, move to trash, open terminal)
6. **Rescan** with the toolbar button, **Cmd/Ctrl+R** or **F5**
7. Click the **gear icon** to change the color scheme

### Command line

```
alocir [--theme NAME] [FOLDER]
```

`FOLDER` is scanned straight away, skipping the start screen. `--theme` picks
the color scheme: `dark`, `purple`, `daylight`, `classic`, `sky` or `phosphor`.

## Dependencies

| Crate | Purpose |
|-------|---------|
| [eframe](https://github.com/emilk/egui/tree/master/crates/eframe) | GUI framework (egui) |
| [rayon](https://github.com/rayon-rs/rayon) | Parallel iteration |
| [rfd](https://github.com/PolyMeilex/rfd) | Native file dialogs |
| [trash](https://github.com/Byron/trash-rs) | Cross-platform trash/recycle bin |
| [notify](https://github.com/notify-rs/notify) | Filesystem watching for live updates |

## Privacy

Alocir collects no data and has no network access. See the [privacy policy](PRIVACY.md).

## License

Apache-2.0
