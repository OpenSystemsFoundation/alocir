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

    /// Settings for screenshot runs, cleared at the start of each, so the
    /// fixed settings of a scene never reach the user's own preferences.
    static let defaults: UserDefaults = {
        let suite = "screenshot-settings"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()

    static let scenes = [
        "start", "start-dark", "scanning", "map", "map-dark", "drilldown",
        "search", "selection-dark", "context-menu", "tabs", "settings", "settings-dark",
        // Not captured in CI (a full-screen window gets its own Space): run by
        // hand to check full screen.
        "fullscreen", "fullscreen-dark",
        // The map with classic colors.
        "classic", "classic-dark",
    ]

    static let windowSize = CGSize(width: 1280, height: 800)
    private static var staged = false

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
        settings.classicColors = baseScene.hasPrefix("classic")
        settings.nestingDepth = 4
        settings.showLabels = true
        settings.showInspector = true
        RecentFolders.shared.replaceForDemo(DemoData.recents())
        NSApplication.shared.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Sets the window's session up for the scene, waits for it to settle,
    /// and reports the window to capture.
    static func stage(_ session: Session, openSettings: OpenSettingsAction, openWindow: OpenWindowAction) async {
        // Only the first window: the "tabs" scene opens a second one.
        guard isActive, session.isIdle, !staged else { return }
        staged = true
        print("ALOCIR_STAGE=\(scene ?? "") uptime=\(Int(ProcessInfo.processInfo.systemUptime))")
        fflush(stdout)
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
        case "map", "drilldown", "search", "selection", "context-menu", "tabs", "fullscreen", "classic":
            session.showDemo(root, path: DemoData.path)
        default:
            break
        }

        guard let window = await mainWindow() else {
            print("ALOCIR_ERROR=no window")
            fflush(stdout)
            return
        }
        // Whole-screen scenes need the menu bar and the menu in view.
        var size = windowSize
        if scene == "context-menu", let visible = window.screen?.visibleFrame.size {
            size = CGSize(width: min(size.width, visible.width - 80), height: min(size.height, visible.height - 120))
        }
        window.setContentSize(size)
        window.center()
        // Launched from a script, the app starts behind the frontmost one;
        // an inactive window draws its controls dimmed.
        NSApplication.shared.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

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
        case "tabs", "fullscreen":
            // A second scan tab (on its start screen), then back to the map,
            // so the tab bar shows both.
            TabRequests.shared.openTab(openWindow: openWindow)
            try? await Task.sleep(for: .seconds(1))
            window.makeKeyAndOrderFront(nil)
            if window.tabbedWindows?.count != 2 {
                print("ALOCIR_NOTE=tabs: \(window.tabbedWindows?.count ?? 1) in the group")
                fflush(stdout)
            }
        default:
            break
        }
        if scene == "fullscreen" {
            window.toggleFullScreen(nil)
            // The full-screen animation, and the toolbar settling.
            try? await Task.sleep(for: .seconds(2))
            if !window.styleMask.contains(.fullScreen) {
                print("ALOCIR_NOTE=fullscreen: the window did not enter full screen")
                fflush(stdout)
            }
        }

        try? await Task.sleep(for: .seconds(2))
        if !NSApplication.shared.isActive {
            print("ALOCIR_NOTE=not active")
        }

        switch scene {
        case "settings":
            let settingsWindow = NSApplication.shared.windows.first {
                $0.isVisible && $0 !== window && !$0.isSheet && $0.frame.width > 200
            }
            report(settingsWindow ?? window, mode: "window")
        case "fullscreen":
            report(window, mode: "screen")
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

    /// Opens the map's context menu over a tile left of centre: asks the
    /// view under that point for its menu, as a right click would.
    private static func rightClick(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let point = NSPoint(x: content.bounds.width * 0.3, y: content.bounds.height * 0.45)
        let location = content.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        var view = content.hitTest(content.superview.map { content.convert(point, to: $0) } ?? point)
        while let candidate = view {
            if let menu = candidate.menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: candidate)
                return
            }
            view = candidate.superview
        }
        print("ALOCIR_NOTE=no context menu at \(point)")
        fflush(stdout)
        window.sendEvent(event)
    }
}
