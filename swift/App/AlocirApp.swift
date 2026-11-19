import AlocirCore
import AppKit
import SwiftUI

@main
struct AlocirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        ScreenshotMode.prepare()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            WindowRoot()
                .environment(AppSettings.shared)
                .environment(RecentFolders.shared)
                .environment(OpenRequests.shared)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { AlocirCommands() }

        Settings {
            SettingsView()
                .environment(AppSettings.shared)
                .environment(RecentFolders.shared)
                .preferredColorScheme(AppSettings.shared.appearance.colorScheme)
        }
    }
}

/// One window: its own Session, and the screen for the session's phase.
struct WindowRoot: View {
    @State private var session = Session(isDemo: ScreenshotMode.isActive)
    @Environment(AppSettings.self) private var settings
    @Environment(OpenRequests.self) private var requests
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        RootView(session: session)
            .frame(minWidth: 760, minHeight: 520)
            .preferredColorScheme(settings.appearance.colorScheme)
            .focusedSceneValue(\FocusedValues.session, session)
            .background(WindowAccessor { window in adopt(window) })
            .onAppear { claimPendingFolder() }
            .onChange(of: requests.pending) { claimPendingFolder() }
            .task {
                guard ScreenshotMode.isActive else { return }
                await ScreenshotMode.stage(session, openSettings: openSettings, openWindow: openWindow)
            }
    }

    /// Every scan window can be a tab of another. A window opened for a tab
    /// request joins the window it was asked from, and scans the request's
    /// folder if it has one.
    private func adopt(_ window: NSWindow) {
        window.tabbingIdentifier = TabRequests.tabbingIdentifier
        guard let request = TabRequests.shared.take(for: window) else { return }
        if let host = request.host, host !== window, host.isVisible {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        if let folder = request.folder {
            session.open(folder)
        }
    }

    /// Folders dropped on the Dock icon or opened from Finder go to an idle
    /// window; when there is none, one window opens a new one for them.
    private func claimPendingFolder() {
        guard !requests.pending.isEmpty else { return }
        if session.isIdle, let url = requests.take() {
            session.open(url)
            return
        }
        Task {
            await Task.yield()
            if requests.needsWindow() { openWindow(id: "main") }
        }
    }
}

/// Switches between the start screen, the scan and the map.
struct RootView: View {
    let session: Session

    var body: some View {
        switch session.phase {
        case .start:
            StartView(session: session)
                .navigationTitle("Alocir")
        case .scanning(let scan):
            ScanningView(session: session, scan: scan)
        case .map(let tree):
            MapView(session: session, tree: tree)
                .id(ObjectIdentifier(tree))
        }
    }
}

// MARK: - Tabs

/// New tabs: each scan is a window, and a window opened through here joins
/// the window it was asked from as a tab (the system's own window tabs, with
/// their tab bar, Merge All Windows and dragging a tab out).
@MainActor
final class TabRequests {
    static let shared = TabRequests()
    static let tabbingIdentifier = "com.jeffkroon.alocir.scan"

    struct Request {
        /// The window the tab joins.
        weak var host: NSWindow?
        /// Scanned in the new tab right away; `nil` shows the start screen.
        var folder: URL?
        /// Windows that existed when the tab was asked for: none of them is
        /// the new tab, even if it reports in late.
        var existing: Set<Int>
    }

    private var pending: [Request] = []

    /// Opens a tab next to the key window, optionally scanning `folder`.
    func openTab(folder: URL? = nil, openWindow: OpenWindowAction) {
        let existing = Set(NSApp.windows.map(\.windowNumber))
        pending.append(Request(host: Self.hostWindow(), folder: folder, existing: existing))
        openWindow(id: "main")
    }

    /// The window a new tab joins: the key window, or when the app isn't
    /// active (in the background, or opening a folder from the Dock) the
    /// frontmost scan window.
    private static func hostWindow() -> NSWindow? {
        func isScanWindow(_ window: NSWindow?) -> Bool {
            guard let window else { return false }
            // SwiftUI names the windows of the "main" group "main-…".
            return window.isVisible && (window.identifier?.rawValue.hasPrefix("main") ?? false)
        }
        if isScanWindow(NSApp.keyWindow) { return NSApp.keyWindow }
        if isScanWindow(NSApp.mainWindow) { return NSApp.mainWindow }
        return NSApp.orderedWindows.first(where: isScanWindow)
    }

    /// Asks for a folder, then scans it in a new tab.
    func scanFolderInNewTab(openWindow: OpenWindowAction) {
        guard let folder = Session.pickFolder() else { return }
        openTab(folder: folder, openWindow: openWindow)
    }

    /// The oldest request `window` can be the tab for.
    func take(for window: NSWindow) -> Request? {
        guard let index = pending.firstIndex(where: { !$0.existing.contains(window.windowNumber) }) else { return nil }
        return pending.remove(at: index)
    }
}

/// Hands the NSWindow a SwiftUI view lives in to `onWindow`, once.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowTrackingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowTrackingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let onWindow else { return }
            self.onWindow = nil
            onWindow(window)
        }
    }
}

// MARK: - Opening folders from Finder and the Dock

/// Folders the system asked the app to open, waiting for a window.
@MainActor
@Observable
final class OpenRequests {
    static let shared = OpenRequests()
    private(set) var pending: [URL] = []
    @ObservationIgnored private var windowRequested = false

    func add(_ urls: [URL]) {
        pending.append(contentsOf: urls)
    }

    func take() -> URL? {
        guard !pending.isEmpty else { return nil }
        windowRequested = false
        return pending.removeFirst()
    }

    /// True once per batch of folders that no idle window claimed.
    func needsWindow() -> Bool {
        guard !pending.isEmpty, !windowRequested else { return false }
        windowRequested = true
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !folders.isEmpty else { return }
        OpenRequests.shared.add(folders)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Menu commands

struct AlocirCommands: Commands {
    @FocusedValue(\.session) private var session
    @FocusedValue(\.focusSearch) private var focusSearch
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n")
            Button("New Tab") { TabRequests.shared.openTab(openWindow: openWindow) }
                .keyboardShortcut("t")
            Button("Open in New Tab…") { TabRequests.shared.scanFolderInNewTab(openWindow: openWindow) }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Open…") {
                if let session {
                    session.chooseFolder()
                } else {
                    openWindow(id: "main")
                }
            }
            .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(RecentFolders.shared.entries) { entry in
                    Button(entry.name) { session?.open(entry) }
                        .disabled(session == nil)
                }
                Divider()
                Button("Clear Menu") { RecentFolders.shared.clear() }
                    .disabled(RecentFolders.shared.entries.isEmpty)
            }
            Divider()
            Button("Close Scan") { session?.closeTree() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(session?.isIdle ?? true)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { focusSearch?() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(AppSettings.shared.showInspector ? "Hide Inspector" : "Show Inspector") {
                AppSettings.shared.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("Show Labels", isOn: Binding(
                get: { AppSettings.shared.showLabels },
                set: { AppSettings.shared.showLabels = $0 }))
            Divider()
        }

        CommandMenu("Go") {
            Button("Rescan") { session?.rescan() }
                .keyboardShortcut("r")
                .disabled(session?.tree == nil)
            Divider()
            Button("Zoom In") {
                if let session, let node = session.tree?.selection, node.isDirectory {
                    session.zoom(into: node, fromRect: nil)
                }
            }
            .keyboardShortcut(.downArrow)
            .disabled(!(session?.tree?.selection?.isDirectory ?? false))
            Button("Enclosing Folder") { session?.zoomOut() }
                .keyboardShortcut(.upArrow)
                .disabled(session?.tree?.focus.parent == nil)
            Button("Top Level") {
                if let session, let root = session.tree?.root { session.go(to: root) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            .disabled(session?.tree?.focus.parent == nil)
        }

        CommandMenu("Item") {
            let node = session?.tree?.selection
            Button("Open") { if let node { session?.openItem(node) } }
                .disabled(node == nil)
            Button("Show in Finder") { if let node { session?.revealInFinder(node) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(node == nil)
            Button("Quick Look") { if let node { session?.quickLook(node) } }
                .keyboardShortcut("y")
                .disabled(node == nil)
            Button("Copy Path") { if let node { session?.copyPath(node) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(node == nil)
            Divider()
            Button("Rename…") { session?.renaming = node }
                .disabled(node == nil || node === session?.tree?.root)
            Button("Move to Trash") { if let node { session?.moveToTrash(node) } }
                .keyboardShortcut(.delete)
                .disabled(node == nil || node === session?.tree?.root)
        }
    }
}
