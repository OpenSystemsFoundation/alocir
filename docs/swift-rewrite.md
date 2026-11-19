# Alocir 2.0: native Swift rewrite

This is the design and the work order for rebuilding the macOS app in Swift.
It is written for an agent working in this repository without the earlier
conversation. Read `AGENTS.md` first; its rules still apply.

## 1. Goal

Replace the macOS build of Alocir (Rust + egui, `crates/alocir`) with a native
Swift app that:

- puts performance first: scan speed, memory per file, and a treemap that
  stays at display refresh rate with millions of files scanned;
- looks and behaves like a first-party macOS app, using the system glass
  design (Liquid Glass), and runs on macOS 26 and later;
- adds the four features the Rust app lacks: a **nested treemap**, **search
  and filter**, **persistent settings and recent folders**, and **keyboard
  navigation between tiles**;
- ships free and open source (Apache-2.0) on the Mac App Store, as version
  **2.0.0** of the existing app record.

### Not in scope

- Windows and Linux. The Rust workspace stays as it is and keeps serving
  them. Do not delete or restructure `crates/`, `vendor/` or the Rust CI jobs.
- Duplicate detection, usage trends, report export, a colour scheme editor.
- Uploading to App Store Connect or submitting for review. The human does
  that. Never run an upload.

## 2. Read this before you start: you cannot build this on Linux

A cloud session runs on Linux. It has no Xcode and no macOS SDK, so it cannot
compile SwiftUI, AppKit, FSEvents or `getattrlistbulk` code, and it cannot
launch the app.

Work like this instead:

1. **Make CI your compiler, first.** Milestone 0 adds a macOS job to
   `.github/workflows/ci.yml` that builds the Swift package, runs its tests
   and builds the app with `xcodebuild`. Push, then read the result with
   `gh run watch` / `gh run view --log-failed`. Nothing counts as done until
   that job is green.
2. **Build with the macOS 27 SDK (Xcode 27), the newest.** Checked on
   2026-11-16: `macos-latest` is the macOS 26 image, whose newest Xcode is
   26.6 with the macOS 26.5 SDK, so it is not enough. GitHub lists a separate
   image with the labels `xcode-27` and `xcode-27-xlarge`, marked preview.
   Use `runs-on: xcode-27` for the Swift job and print `xcodebuild -version`
   and the SDK version as its first step. Check the `actions/runner-images`
   README again before writing the job, since a preview label can change. If
   no hosted runner has Xcode 27, stop and tell the human; do not fall back
   to the 26 SDK or change the deployment target to make CI pass.
3. **Do not trust your memory of macOS 26 or 27 APIs.** Confirm every glass-related
   API against Apple's documentation, and let the compiler in CI settle it.
   The human's Mac has Xcode 27.2, Swift 6.4.2 and the macOS 27.2 SDK; these
   were confirmed present in that SDK: `GlassButtonStyle` (`.glass`,
   `.glassProminent`), `backgroundExtensionEffect()`, `scrollEdgeEffectStyle`,
   `searchToolbarBehavior`, `ToolbarSpacer`. `glassEffect(_:in:)` and
   `GlassEffectContainer` were not confirmed either way; check them.
4. **Say what was not verified.** Nothing visual can be checked from a cloud
   session. The final report must list what needs a human at a Mac: look and
   feel, animation, sandbox behaviour, Dock drops, Quick Look.

## 3. Repository rules that apply

- **No third-party names** in theme names, UI text or store text. Names of
  the platform's own parts ("Finder", "Trash", "Quick Look") are fine.
- **No private APIs.** Public Swift and Objective-C API only; no `@_spi`, no
  undocumented selectors, no `dlsym`. Run `scripts/check-private-apis.sh` on
  the built `.app` in CI.
- **No package dependencies.** The app uses only the system frameworks. This
  keeps the binary small and the private-API surface under our control.
- **No network.** No network entitlement, no analytics. `PRIVACY.md` must
  stay true.
- **Never slice strings by byte index** for display. Truncate by `Character`.
- **Commits and PRs carry no AI attribution**: no `Co-Authored-By` trailer
  and no "Generated with" line. This is the maintainer's standing rule.
- Work on the `swift-rewrite` branch. Open one draft PR against `main` and
  keep pushing to it.

## 4. Layout

Everything new lives under `swift/`:

```
swift/
  Package.swift                 AlocirCore library, its tests, alocir-scan tool
  Sources/AlocirCore/           Engine. No SwiftUI, no AppKit.
    FileNode.swift              Tree node, path building
    FileKind.swift              Extension -> kind category
    DirectoryReader.swift       getattrlistbulk reader, readdir fallback
    Scanner.swift               Parallel scan, progress, cancellation
    LiveTree.swift              In-memory tree edits and reconcile-with-disk
    FSEventsWatcher.swift       FSEvents stream -> batches of paths
    Treemap.swift               Squarify, nested layout, hit test, key moves
    Search.swift                Query parsing and matching
    Formatting.swift            Sizes, counts, durations, truncation
  Sources/alocir-scan/          CLI: scan a path, print total and timing
  Tests/AlocirCoreTests/        Swift Testing
  App/                          App target sources (synchronized folder)
    AlocirApp.swift             App, scenes, menu commands
    Model/                      Session, Settings, RecentFolders
    Views/                      Start, Scanning, Treemap, Inspector, ...
    Assets.xcassets             AccentColor, AppIcon
    Info.plist                  Only the keys build settings cannot express
    Alocir.entitlements
  Alocir.xcodeproj              One app target, depends on the local package
  scripts/archive.sh            Archive and export a store package (no upload)
```

Use an Xcode project (`objectVersion = 77`) with a
`PBXFileSystemSynchronizedRootGroup` for `App/`, so files added to the folder
need no project edits. The engine is a local Swift package so `swift test`
runs it without Xcode's build system.

## 5. Baseline

| Item | Value |
|---|---|
| Build SDK | macOS 27 (Xcode 27), the newest |
| Deployment target | macOS 26.0. Guard anything newer with `if #available` (the compiler enforces it) |
| Language | Swift 6 language mode, complete strict concurrency |
| UI | SwiftUI. AppKit only where SwiftUI has no equivalent |
| State | `@Observable` models; no `ObservableObject`, no Combine |
| Concurrency | `async`/`await`, `Synchronization.Mutex` and `Atomic` |
| Tests | Swift Testing (`@Test`, `#expect`) |
| Bundle ID | `com.jeffkroon.alocir` (permanent; the store record uses it) |
| Team ID | `45X6674984` |
| Version | 2.0.0. `CFBundleVersion` must exceed 31, the last upload (1.0.0) |
| Category | `public.app-category.utilities` |
| Architectures | Universal (arm64 + x86_64); `ci.sh` fails without both |

## 6. Engine (`AlocirCore`)

Port behaviour from the Rust code, not its structure. The Rust files to read
are `crates/shared/src/scanner.rs`, `crates/shared/src/treemap.rs` and
`crates/alocir/src/app.rs` (reconcile logic and its tests).

### 6.1 Tree

```swift
public final class FileNode: @unchecked Sendable {
    public let name: String
    public internal(set) var size: UInt64        // allocated bytes
    public internal(set) var children: [FileNode] // sorted by size, descending
    public internal(set) unowned(unsafe) var parent: FileNode?
    public let isDirectory: Bool
    public let kind: FileKind                     // UInt8-backed
    public var searchMark: UInt8                  // see 6.6
}
```

`@unchecked Sendable` is deliberate, and the rule that makes it safe must be
written on the type: a subtree is built by the scanner off the main actor,
handed over once, and from then on read and mutated on the main actor only.

Children are always sorted by size, largest first. The layout depends on it.

### 6.2 Scanner

Sizes are **disk usage**, exactly as in the Rust app:

- Files count their allocated size. Directories count the sum of their
  children; a directory's own blocks are not counted.
- Symlinks are skipped. Sockets, FIFOs and devices are zero-size files.
- A file with a link count above 1 is counted once per scan, keyed by
  `(device, inode)`.
- Every directory is visited once per scan, keyed by `(device, inode)`. This
  is what stops firmlinks such as `/Users` being counted twice.
- `/System/Volumes/Data` is scanned **last** when the scan contains it and it
  is not the scan root, then grafted into the tree, so data is counted under
  the familiar paths.
- Unreadable directories become empty directories. They never stop a scan.

How to make it fast:

- Read each directory with **`getattrlistbulk`**: one system call returns
  name, type, link count, file id and allocated size for hundreds of entries,
  where the Rust app makes one `lstat` per file. Request
  `ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID |
  ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID` and `ATTR_FILE_LINKCOUNT |
  ATTR_FILE_ALLOCSIZE`. Parse per the `getattrlistbulk(2)` manual page:
  check each field against the returned-attributes bitmap, read the name
  through its `attrreference_t` offset, and use unaligned loads (fields are
  4-byte aligned, the file id is 8 bytes).
- Fall back to `readdir` + `fstatat(AT_SYMLINK_NOFOLLOW)` with
  `st_blocks * 512` when `getattrlistbulk` fails with `ENOTSUP` or `EINVAL`
  (some network and third-party filesystems).
- After opening a directory, `fstat` its descriptor for the `(device, inode)`
  used in the visited set. Do not rely on the parent's listing for that at
  mount points.
- Open directories by full path with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW`.
  Do not hold a parent descriptor open while its children are scanned: GUI
  apps start with a soft limit of 256 descriptors.
- Parallelism: handle a directory's files inline and its subdirectories with
  nested `DispatchQueue.concurrentPerform`, run from a dedicated queue and
  bridged to `async` with a continuation. Do not block Swift's cooperative
  thread pool with file system calls.
- Shared state: `Atomic<UInt64>` counters updated once per directory, not per
  file; `Mutex`-guarded sets for visited directories and hard links, locked
  once per directory and once per hard-linked file.
- Cancellation: an `Atomic<Bool>` checked once per directory, set when the
  calling task is cancelled.
- Progress: items, bytes and the current path, the path published at most
  every 50 ms.
- `FileKind` is computed in the scanner from the name's extension and stored
  in the node, so painting never touches strings.

A test must assert that the allocated size from `getattrlistbulk` equals
`st_blocks * 512` from `lstat` for ordinary, sparse and hard-linked files.

### 6.3 Live tree and reconciliation

`LiveTree` owns the root, the scan path and its canonical form (FSEvents
reports `/private/var/...` for `/var/...`). Port these from `app.rs` with
their tests:

- `reconcile(path)`: do not trust the event kind. `lstat` the path and make
  the tree match: add, resize or remove the entry, fix every ancestor's size
  and keep each level sorted. If a directory on the way is missing from the
  tree, reconcile the highest missing one instead.
- A directory that appears gets a zero-size placeholder immediately and a
  background scan that replaces it.
- Background scans are tracked per path. A scan of an ancestor supersedes
  scans below it; a path that changes while its scan runs is scanned again.
- A "must rescan" event rescans the deepest directory the tree knows on that
  path.
- Navigation and selection are held as node references, so re-sorting does
  not move them. When the focused folder is deleted, fall back to its nearest
  surviving ancestor.
- Every mutation bumps a `version` counter that the layout and search watch.

### 6.4 Watching

One recursive FSEvents stream on the scan root: `FSEventStreamCreate` with
file-level events, about 0.3 s latency, delivered on a dispatch queue and
passed to the main actor as an `AsyncStream` of batches. Deduplicate paths in
a batch. Map `MustScanSubDirs`, `UserDropped` and `KernelDropped` to rescans.
There is no "Watch subfolders" setting on macOS; that was a Linux limit.

### 6.5 Treemap layout

`squarify` is the same algorithm as `treemap.rs` (iterative, tracking a row's
largest and smallest area). Two changes:

- **Early exit.** Children are sorted, so once a row would be thinner than
  one point, stop: nothing after it can be drawn. The Rust app laid out every
  child and filtered afterwards.
- **Nesting.** A directory tile that is large enough gets a header strip and
  a small inset, and its children are laid out inside it, recursively, down
  to a maximum depth from settings (default 4) or until tiles are too small.

Output is one flat array, parents before children:

```swift
public struct Tile { var rect: CGRect; var node: FileNode; var depth: UInt8; var showsChildren: Bool }
```

Also in this file, all pure and tested:

- `hitTest(point)`: the deepest tile containing the point.
- `move(from:direction:)` for arrow keys: probe a point just past the
  selected tile's edge, hit-test it, climb to the tile at the selection's
  depth, and keep stepping while the result is the selection or one of its
  ancestors.

The layout is recomputed only when the tree version, the focused folder, the
view size or the depth setting changes. Never per frame.

### 6.6 Search

Query grammar, tokens separated by spaces, all must match:

| Token | Meaning |
|---|---|
| `report` | Name contains it, ignoring case |
| `.mp4` or `*.mp4` | Name ends with that extension |
| `>500mb`, `<1gb` | Size above or below (`kb`, `mb`, `gb`, `tb`) |

Matching ASCII queries works on UTF-8 bytes with ASCII case folding; other
queries fall back to Foundation's case- and diacritic-insensitive compare.

The search runs **on the main actor in slices**: an explicit-stack traversal
that handles a few milliseconds of nodes, then yields. That keeps the UI live
and needs no locking against tree edits. Restart it when the query or the
tree version changes, debounced by about 150 ms.

Results: the matching nodes, their count and total size. Matches set a bit in
`searchMark` and their ancestors another, so the painter can dim everything
else without a lookup. Clear the marks of the previous result first.

## 7. App

### 7.1 Structure

- `WindowGroup`: each window owns one `Session` (`@Observable`,
  `@MainActor`), so "New Window" gives an independent scan.
- `Settings` scene for preferences.
- `Session.phase`: `.start`, `.scanning(progress)`, `.map`.
- Menu commands through `Commands` and `FocusedValue`, so every shortcut also
  has a menu item.

### 7.2 Sandbox

There is one build and it is always sandboxed. Entitlements:

```
com.apple.security.app-sandbox                    true
com.apple.security.files.user-selected.read-write true
com.apple.security.files.bookmarks.app-scope      true
```

Do not put the application or team identifier in the file; Xcode adds them
when signing for distribution, and they stop an ad-hoc build from launching.

Consequences to design around:

- A folder is only readable after the user picks it in an open panel, drops
  it on the window, or drops it on the Dock icon. "Home" and "Startup Disk"
  buttons open the panel at that location; they cannot skip it.
- Recent folders are stored as **security-scoped bookmarks**. Resolve, call
  `startAccessingSecurityScopedResource`, and stop when the session closes.
  Refresh stale bookmarks.
- No "Open Terminal Here" and no command-line folder argument.
- Trash with `FileManager.trashItem`, rename with `FileManager.moveItem`,
  reveal with `NSWorkspace.activateFileViewerSelecting`, open with
  `NSWorkspace.open`.
- Explain Full Disk Access on the start screen in one line: whole-disk scans
  skip protected folders until the user grants it in System Settings.

### 7.3 Screens

**Start.** A centred hero on a full-window background: app icon, one line of
text, a prominent glass "Choose Folder…" button, secondary "Home" and
"Startup Disk" buttons, and a list of recent folders with size and date of
the last scan. The whole window is a drop target.

**Scanning.** The folder name, three live figures (items, size, elapsed) in
glass cards, the current path in monospaced digits-friendly type, and Cancel.
The roadmap asks for a percentage: when the scan root is a whole volume, show
determinate progress as bytes scanned over the volume's used space
(`volumeTotalCapacity − volumeAvailableCapacity`); otherwise stay
indeterminate.

**Map.** The treemap fills the window edge to edge and runs under the
toolbar. Around it:

- Toolbar: Up, the breadcrumb as the principal item, search field, Rescan,
  inspector toggle. Let the system supply the glass; do not paint custom
  toolbar backgrounds.
- A floating glass capsule at the bottom showing the hovered item: name,
  size, share of the focused folder. It shows errors for six seconds.
- An inspector (`.inspector`) on the trailing side with three parts: the
  selected item (icon, name, size, share, path, action buttons); a breakdown
  of the focused folder by kind, which doubles as the colour legend; and the
  largest items, or the search results while a query is active.

### 7.4 Drawing the treemap

- One SwiftUI `Canvas` draws all tiles. It depends only on the layout, the
  palette and the search state.
- **Hover and selection are separate overlay views**, so moving the pointer
  never redraws the canvas.
- Batch fills: build one `Path` per colour and fill each once. Draw the
  gloss gradient and labels only for tiles above a size threshold, and cap
  labels at a few hundred.
- Files are coloured by kind. Folders are containers: a darker translucent
  frame with a header showing name and size.
- Truncate labels by `Character` to an estimated fit and clip to the tile.
- Zooming into a folder animates from that tile's rectangle to the full view,
  and back out in reverse. Respect Reduce Motion with a plain cross-fade.
- Honour Increase Contrast and Reduce Transparency. Give the canvas
  accessibility children for at least the top-level tiles (name and size).

### 7.5 Interaction

| Input | Action |
|---|---|
| Hover | Highlight deepest tile, show it in the status capsule |
| Click | Select the tile |
| Double-click folder | Zoom into it |
| Double-click file, Space | Quick Look |
| Right-click | Menu: Open, Show in Finder, Quick Look, Copy Path, Rename…, Move to Trash |
| Arrow keys | Move selection spatially |
| ⌥↑ / ⌥↓ | Select enclosing folder / largest child |
| ⌘↓ | Zoom into selection |
| ⌘↑, Delete | Zoom out one level |
| Esc | Clear selection, then clear search |
| Return | Rename |
| ⌘⌫ | Move to Trash |
| ⌘F | Focus search |
| ⌘R | Rescan |
| ⌘O | Choose folder |
| ⌥⌘C | Copy path |
| ⌥⌘I | Toggle inspector |

Rename selects the name without its extension, refuses an existing name
unless only the case differs, and updates the tree in place.

### 7.6 Settings and persistence

Stored in `UserDefaults`:

- Appearance: System, Light, Dark.
- Palette: six generic names (for example Spectrum, Aurora, Ember, Ocean,
  Graphite, Phosphor), each a colour per file kind, checked for label
  contrast in both appearances.
- Nesting depth (1 to 8), show labels, inspector visibility.
- Recent folders (bookmarks, last size, last scan date), capped at ten, with
  a "Clear Recents" command.

Window size and position are restored by the system; do not hand-roll it.

### 7.7 Dock and Finder integration

Declare `public.folder` as a viewer document type in `Info.plist` and handle
`application(_:open:)`, so a folder dropped on the Dock icon starts a scan in
an idle window or a new one.

## 8. Project and release settings

- Info.plist keys through build settings where possible
  (`INFOPLIST_KEY_LSApplicationCategoryType`,
  `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`, copyright). Only the
  document types need the plist file.
- Hardened runtime on. Automatic signing for development with the team above.
- The app icon comes from `assets/logo.svg`. Produce the PNG sizes for the
  asset catalog and note in the PR that a layered icon made in Icon Composer
  is a job for the human.
- `swift/scripts/archive.sh` runs `xcodebuild archive` and `-exportArchive`
  for the store using the existing manual signing material described in
  `docs/mac-app-store.md` (certificate "Apple Distribution", installer
  certificate "3rd Party Mac Developer Installer", profile "Alocir Mac App
  Store"). It takes `BUILD_NUMBER`, runs `scripts/check-private-apis.sh` on
  the result, and stops there. No upload flag.
- The existing `app-store` CI job stays manual. Add the Swift build to it
  only as a second, clearly separate step, and leave the Rust path working.

## 9. Tests and measurements

Port the Rust tests that cover behaviour kept here: scan sums and symlink
skipping, hard links and sparse files, excluded and twice-reached
directories, graft, every reconcile test in `app.rs`, the real-watcher
end-to-end test, and the squarify tests including the 100,000-item one. Add
tests for nesting, early exit, hit testing, arrow-key moves, the search
grammar and the bulk-versus-`lstat` size check.

`alocir-scan PATH` prints item count, total bytes and elapsed time. In CI,
run it and the Rust `scan_total` example on the same generated tree and fail
if the totals differ. CI checks correctness only: hosted runners are shared
virtual machines with small, empty disks, so their timings say nothing about
a real Mac. Do not quote them as results and do not claim a speed-up.

### Benchmark gate: stop after milestone 3

A cloud session cannot run or simulate a Mac, so it cannot benchmark. When
milestone 3 is green, **stop and hand over to the human.** Do not start
milestone 4 until they reply with results.

Before stopping:

- Add `swift/scripts/bench.sh`. It builds `alocir-scan` and the Rust
  `scan_total` example in release mode, runs each three times on the path
  given (once to warm the cache, then timed), and prints item count, total
  bytes, wall time and peak memory (`/usr/bin/time -l`) for both, side by
  side. It also times the nested layout on the scanned tree at 1600×1000.
- Post a PR comment with the exact commands to run on the Mac, for a home
  folder and for `/`, and what to paste back.

When the results come back:

- Totals must match the Rust scanner, and `/` must match `df` as closely as
  the Rust app does.
- If the Swift scanner is not faster than the Rust one, or uses more memory
  per file, fix that before any UI work. The engine is the reason for the
  rewrite.

Frame rate and animation cannot be measured from a cloud session either.
They stay on the manual list in section 11.

## 10. Order of work

Each milestone ends with a push and a green macOS job.

0. **CI.** macOS job, empty package, empty app target that builds.
1. **Engine: tree, reader, scanner**, tests, `alocir-scan`, totals check.
2. **Engine: live tree, FSEvents**, ported reconcile tests.
3. **Engine: nested layout, hit test, key moves, search**, tests.
   **Then stop for the benchmark gate (section 9).** Continue only after the
   human posts results from a real Mac.
4. **App shell:** scenes, session, start and scanning screens, sandboxed
   folder access, recents.
5. **Map:** canvas, overlays, zoom, breadcrumb, status capsule.
6. **Actions:** context menu, rename, trash, Quick Look, all shortcuts.
7. **Inspector, search UI, settings, kinds breakdown.**
8. **Polish and accessibility.** Dock drops. Private-API check in CI.
9. **Docs:** add the Swift app to `AGENTS.md` and `README.md`, update
   `docs/mac-app-store.md` with the 2.0.0 path, check `PRIVACY.md` still
   holds (it must mention that recent folders are remembered on the Mac).

## 11. Done means

- The macOS CI job builds the app, passes every test and the private-API
  check, and the Rust jobs still pass.
- All features in sections 6 and 7 exist, each with a menu item or a visible
  control.
- The PR description lists, plainly: what CI verified, what nobody has seen
  run, and the manual test list for the human (sandbox denials, FSEvents in
  the sandbox, bookmarks after relaunch, Dock drop, Quick Look, trash and
  rename, a whole-disk scan checked against `df`, look and feel in light and
  dark, Reduce Motion, VoiceOver).

## 12. Decisions for the human, not the agent

Carry on with the default; list these in the PR.

| Question | Default taken |
|---|---|
| Does 2.0 replace the Rust app on the store under the same record? | Yes |
| Minimum macOS? | 26 (decided by the maintainer on 2026-11-17, replacing 27 from 2026-11-16): nothing used needs 27, and 26 roughly triples the audience. Older systems the Rust app supported (11+) are dropped |
| Keep a non-sandboxed Developer ID build on GitHub Releases? | No; one sandboxed build |
| Keep Intel support? | Yes: universal, for Intel Macs on macOS 26 |
