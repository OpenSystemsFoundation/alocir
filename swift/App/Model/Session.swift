import AlocirCore
import AppKit
import SwiftUI

/// One window's scan: what phase it is in, the live tree, navigation,
/// search and the actions on files. Each window owns its own Session, so
/// "New Window" gives an independent scan.
@MainActor
@Observable
final class Session {
    enum Phase {
        case start
        case scanning(Scan)
        case map(LiveTree)
    }

    struct Scan {
        let url: URL
        let progress: ScanProgress
        let started: Date
        /// Used bytes of the volume, when the scan root is a whole volume:
        /// progress is then bytes scanned over this.
        let volumeUsedBytes: UInt64?
    }

    struct Notice: Equatable {
        let message: String
        let date: Date
    }

    private(set) var phase: Phase = .start
    let search = TreeSearch()
    var searchText = "" {
        didSet { if let tree { search.setText(searchText, in: tree) } }
    }
    /// The tile under the pointer, shown in the status capsule.
    var hovered: FileNode?
    /// An error shown in the status capsule for six seconds.
    private(set) var notice: Notice?
    var renaming: FileNode?
    var quickLookURL: URL?
    /// Set when a zoom starts, so the map can animate from this tile.
    private(set) var zoom: Zoom?
    /// Demo sessions (screenshots) never touch the disk.
    let isDemo: Bool
    private(set) var lastScanDuration: Duration?
    private(set) var lastScanItems: UInt64?

    struct Zoom: Equatable {
        enum Direction { case into, outOf }
        let direction: Direction
        /// The zoomed folder's tile in the view before (into) or after
        /// (out of) the zoom.
        let rect: CGRect
        let id = UUID()
    }

    @ObservationIgnored private var accessedURL: URL?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(isDemo: Bool = false) {
        self.isDemo = isDemo
    }

    var tree: LiveTree? {
        if case .map(let tree) = phase { return tree }
        return nil
    }

    var scanURL: URL? {
        switch phase {
        case .start: nil
        case .scanning(let scan): scan.url
        case .map(let tree): URL(filePath: tree.scanPath)
        }
    }

    var isIdle: Bool {
        if case .start = phase { return true }
        return false
    }

    // MARK: Opening folders

    /// Asks for a folder with an open panel, starting at `directory`. In the
    /// sandbox this is how a folder becomes readable; "Home" and "Startup
    /// Disk" only choose where the panel opens.
    func chooseFolder(startingAt directory: URL? = nil) {
        guard let url = Self.pickFolder(startingAt: directory) else { return }
        open(url)
    }

    /// The folder picker. The folder it returns is readable by the whole app,
    /// so it can be scanned in another window or tab.
    static func pickFolder(startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Scan")
        panel.message = String(localized: "Choose a folder or disk to scan.")
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Scans `url`. It must be readable: picked in a panel, dropped, or
    /// resolved from a bookmark.
    func open(_ url: URL) {
        closeTree()
        let accessing = url.startAccessingSecurityScopedResource()
        accessedURL = accessing ? url : nil
        let progress = ScanProgress()
        let scan = Scan(url: url, progress: progress, started: .now, volumeUsedBytes: Self.volumeUsedBytes(url))
        phase = .scanning(scan)
        RecentFolders.shared.record(url)
        let path = url.path(percentEncoded: false)
        let clock = ContinuousClock()
        let start = clock.now
        scanTask = Task { [weak self] in
            do {
                let root = try await DiskScanner().scan(path: path, progress: progress)
                guard let self else { return }
                self.lastScanDuration = clock.now - start
                self.lastScanItems = progress.itemsScanned
                let tree = LiveTree(root: root, scanPath: path)
                tree.startWatching()
                self.phase = .map(tree)
                self.search.setText(self.searchText, in: tree)
                RecentFolders.shared.record(url, size: root.size)
            } catch {
                // Cancelled: back to the start screen.
                self?.phase = .start
                self?.stopAccessing()
            }
        }
    }

    func open(_ entry: RecentFolders.Entry) {
        guard let url = RecentFolders.shared.resolve(entry) else {
            show(String(localized: "“\(entry.name)” can’t be opened. Choose it again."))
            RecentFolders.shared.remove(entry)
            return
        }
        open(url)
    }

    /// Shows a ready-made tree (screenshots and previews).
    func showDemo(_ root: FileNode, path: String, scanning: Scan? = nil) {
        if let scanning {
            phase = .scanning(scanning)
        } else {
            phase = .map(LiveTree(root: root, scanPath: path))
            lastScanDuration = .milliseconds(1840)
            lastScanItems = UInt64(root.nodeCount - 1)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = .start
        stopAccessing()
    }

    func rescan() {
        guard let url = scanURL, !isDemo else { return }
        let focusPath = tree?.focus.path
        open(url)
        // Restore the focused folder once the scan is in.
        guard let focusPath else { return }
        Task { [weak self] in
            while let self, case .scanning = self.phase { try? await Task.sleep(for: .milliseconds(50)) }
            guard let self, let tree = self.tree else { return }
            let names = focusPath == tree.scanPath ? [] : focusPath.dropFirst(tree.scanPath.count + (tree.scanPath == "/" ? 0 : 1)).split(separator: "/").map(String.init)
            var node = tree.root
            for name in names {
                guard let next = node.children.first(where: { $0.isDirectory && $0.name == name }) else { break }
                node = next
            }
            tree.focus = node
        }
    }

    /// Back to the start screen.
    func closeTree() {
        scanTask?.cancel()
        scanTask = nil
        tree?.stopWatching()
        phase = .start
        hovered = nil
        stopAccessing()
    }

    private func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    static func volumeUsedBytes(_ url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
            values.isVolume == true, let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return nil }
        return UInt64(max(total - available, 0))
    }

    // MARK: Navigation

    /// Zooms into a folder; `fromRect` is its tile, for the animation.
    func zoom(into node: FileNode, fromRect rect: CGRect?) {
        guard let tree, node.isDirectory, node !== tree.focus else { return }
        if let rect { zoom = Zoom(direction: .into, rect: rect) }
        tree.focus = node
        tree.selection = nil
        hovered = nil
    }

    /// Zooms out one level; `toRect` is where the current folder will sit.
    func zoomOut(toRect rect: CGRect? = nil) {
        guard let tree, let parent = tree.focus.parent else { return }
        let child = tree.focus
        if let rect { zoom = Zoom(direction: .outOf, rect: rect) }
        tree.focus = parent
        tree.selection = child
        hovered = nil
    }

    func go(to node: FileNode) {
        guard let tree, node.isDirectory else { return }
        tree.focus = node
        tree.selection = nil
    }

    func zoomFinished() { zoom = nil }

    // MARK: File actions

    func url(for node: FileNode) -> URL {
        URL(filePath: node.path, directoryHint: node.isDirectory ? .isDirectory : .notDirectory)
    }

    func openItem(_ node: FileNode) {
        guard !isDemo else { return }
        if !NSWorkspace.shared.open(url(for: node)) {
            show(String(localized: "“\(node.name)” could not be opened."))
        }
    }

    func revealInFinder(_ node: FileNode) {
        guard !isDemo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url(for: node)])
    }

    func quickLook(_ node: FileNode) {
        guard !isDemo else { return }
        quickLookURL = url(for: node)
    }

    func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func moveToTrash(_ node: FileNode) {
        guard let tree, node !== tree.root, !isDemo else { return }
        do {
            try FileManager.default.trashItem(at: url(for: node), resultingItemURL: nil)
            if hovered === node { hovered = nil }
            tree.remove(node)
        } catch {
            show(String(localized: "Could not move “\(node.name)” to the Trash: \(error.localizedDescription)"))
        }
    }

    enum RenameError: LocalizedError {
        case empty, invalid, exists
        var errorDescription: String? {
            switch self {
            case .empty: String(localized: "The name can’t be empty.")
            case .invalid: String(localized: "Names can’t contain “/” or start with a dot here.")
            case .exists: String(localized: "An item with that name already exists.")
            }
        }
    }

    /// Renames `node` on disk and in the tree. Refuses a name that exists
    /// unless only its case differs.
    func rename(_ node: FileNode, to newName: String) throws {
        guard let tree, node !== tree.root else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameError.empty }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { throw RenameError.invalid }
        guard trimmed != node.name else { return }
        let source = url(for: node)
        let destination = source.deletingLastPathComponent().appending(path: trimmed)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)),
            trimmed.lowercased() != node.name.lowercased()
        {
            throw RenameError.exists
        }
        if !isDemo {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        tree.rename(node, to: trimmed)
    }

    func show(_ message: String) {
        notice = Notice(message: message, date: .now)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

extension FocusedValues {
    @Entry var session: Session?
}
