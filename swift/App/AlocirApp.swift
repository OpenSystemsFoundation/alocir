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
            .focusedSceneValue(\.session, session)
            .onAppear { claimPendingFolder() }
            .onChange(of: requests.pending) { claimPendingFolder() }
            .task {
                guard ScreenshotMode.isActive else { return }
                await ScreenshotMode.stage(session, openSettings: openSettings)
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
