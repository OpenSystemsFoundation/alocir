import AlocirCore
import AppKit
import SwiftUI

/// Screenshot mode, for CI: `Alocir -screenshot <scene>` shows one scene
/// with demo data in a fixed-size window, then prints
/// `ALOCIR_WINDOW=<window number> MODE=<window|screen>` so a script can
/// capture it with `screencapture`. A `-dark` suffix on the scene switches
/// to dark mode. Nothing on disk is read, changed or watched.
@MainActor
enum ScreenshotMode {
    static let scene: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screenshot"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    static var isActive: Bool { scene != nil }

    static let scenes = [
        "start", "start-dark", "scanning", "map", "map-dark", "drilldown",
        "search", "selection-dark", "context-menu", "settings", "settings-dark",
    ]

    static let windowSize = CGSize(width: 1280, height: 800)

    private static var isDark: Bool { scene?.hasSuffix("-dark") ?? false }
    private static var baseScene: String {
        guard let scene else { return "" }
        return isDark ? String(scene.dropLast("-dark".count)) : scene
    }

    /// Fixed settings and recents, before any window appears.
    static func prepare() {
        guard isActive else { return }
        let settings = AppSettings.shared
        settings.appearance = isDark ? .dark : .light
        settings.palette = .spectrum
        settings.nestingDepth = 4
        settings.showLabels = true
        settings.showInspector = true
        RecentFolders.shared.replaceForDemo(DemoData.recents())
        NSApplication.shared.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Sets the window's session up for the scene, waits for it to settle,
    /// and reports the window to capture.
    static func stage(_ session: Session, openSettings: OpenSettingsAction) async {
        guard isActive, session.isIdle else { return }
        let root = DemoData.homeFolder()
        let scene = baseScene

        switch scene {
        case "scanning":
            let progress = ScanProgress(
                items: 684_212, bytes: 148_300_000_000,
                currentPath: "/Users/demo/Library/Application Support/Music Studio/Samples")
            let scan = Session.Scan(
                url: URL(filePath: "/"), progress: progress,
                started: .now.addingTimeInterval(-14), volumeUsedBytes: 402_000_000_000)
            session.showDemo(root, path: DemoData.path, scanning: scan)
        case "map", "drilldown", "search", "selection", "context-menu":
            session.showDemo(root, path: DemoData.path)
        default:
            break
        }

        guard let window = await mainWindow() else {
            print("ALOCIR_ERROR=no window")
            fflush(stdout)
            return
        }
        window.setContentSize(windowSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()

        let tree = session.tree
        switch scene {
        case "drilldown":
            if let tree, let library = tree.root.children.first(where: { $0.name == "Library" }) {
                session.go(to: library)
                tree.selection = library.children.first
            }
        case "search":
            session.searchText = ">1gb"
        case "selection", "context-menu":
            if let tree, let movies = tree.root.children.first(where: { $0.name == "Movies" }) {
                tree.selection = movies.children.first { !$0.isDirectory } ?? movies
            }
        case "settings":
            openSettings()
        default:
            break
        }

        try? await Task.sleep(for: .seconds(2))

        switch scene {
        case "settings":
            let settingsWindow = NSApplication.shared.windows.first {
                $0.isVisible && $0 !== window && !$0.isSheet && $0.frame.width > 200
            }
            report(settingsWindow ?? window, mode: "window")
        case "context-menu":
            report(window, mode: "screen")
            try? await Task.sleep(for: .milliseconds(200))
            rightClick(in: window)
        default:
            report(window, mode: "window")
        }
    }

    private static func mainWindow() async -> NSWindow? {
        for _ in 0..<50 {
            if let window = NSApplication.shared.windows.first(where: {
                $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") ?? false)
            }) ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                return window
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func report(_ window: NSWindow, mode: String) {
        print("ALOCIR_WINDOW=\(window.windowNumber) MODE=\(mode)")
        fflush(stdout)
    }

    /// Opens the map's context menu over a tile left of centre.
    private static func rightClick(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let point = NSPoint(x: content.bounds.width * 0.3, y: content.bounds.height * 0.45)
        for type in [NSEvent.EventType.mouseMoved, .rightMouseDown] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0)
            else { continue }
            NSApplication.shared.postEvent(event, atStart: false)
        }
    }
}
