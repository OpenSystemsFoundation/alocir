import Darwin
import Observation

/// A scanned tree kept in line with the disk.
///
/// Owns the root (and so keeps every node alive: `FileNode.parent` is
/// unowned), the scan path and its canonical form (FSEvents reports
/// `/private/var/...` for `/var/...`). Main-actor only: the scanner builds
/// subtrees off the main actor and hands each over exactly once.
///
/// Every mutation bumps `version`, which layout and search watch.
@MainActor
@Observable
public final class LiveTree {
    public private(set) var root: FileNode
    /// The path the user scanned, without a trailing slash.
    public let scanPath: String
    /// `scanPath` with symlinks resolved.
    public let canonicalPath: String
    public private(set) var version: UInt64 = 0

    /// The folder on screen. Held by reference, so re-sorting never moves it;
    /// if it is deleted, it falls back to its nearest surviving ancestor.
    public var focus: FileNode
    /// The selected tile, if any. Cleared when it is deleted.
    public var selection: FileNode?

    @ObservationIgnored let scanner: DiskScanner
    /// Background scans by path: an id (so a superseded scan's result is
    /// ignored) and whether the directory changed while it ran.
    @ObservationIgnored private var pendingScans: [String: (id: UInt64, changed: Bool)] = [:]
    @ObservationIgnored private var tasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextScanID: UInt64 = 0
    @ObservationIgnored private var watcher: FSEventsWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    public init(root: FileNode, scanPath: String, scanner: DiskScanner = DiskScanner()) {
        let path = DiskScanner.normalize(scanPath)
        self.root = root
        self.focus = root
        self.scanPath = path
        self.canonicalPath = Self.realPath(path) ?? path
        self.scanner = scanner
    }

    /// Paths with a background scan running (for tests and diagnostics).
    public var scansInFlight: [String] { Array(pendingScans.keys) }

    // MARK: Watching

    /// Starts one recursive FSEvents stream on the scan root and applies its
    /// batches as they arrive.
    public func startWatching(latency: Double = 0.3) {
        guard watcher == nil, let watcher = FSEventsWatcher(path: canonicalPath, latency: latency) else {
            return
        }
        self.watcher = watcher
        let batches = watcher.batches
        watchTask = Task { [weak self] in
            for await batch in batches {
                guard let self else { return }
                self.apply(batch)
            }
        }
    }

    public func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        watcher?.stop()
        watcher = nil
    }

    public var isWatching: Bool { watcher != nil }

    /// Applies one batch of file-system events.
    public func apply(_ batch: FSEventsWatcher.Batch) {
        // Scans already running may have read these directories before the
        // changes happened.
        for path in batch.paths + batch.rescans {
            var dir = scanPathForm(path)
            while true {
                if pendingScans[dir] != nil { pendingScans[dir]!.changed = true }
                guard dir != "/", let slash = dir.lastIndex(of: "/") else { break }
                dir = slash == dir.startIndex ? "/" : String(dir[..<slash])
            }
        }
        // Do not trust the event kind (renames, moves and trashing arrive as
        // "renamed" without saying which side a path is): look at the disk.
        for path in batch.paths { reconcile(path) }
        for path in batch.rescans { rescan(path) }
    }

    // MARK: Reconciling

    /// Brings the entry for `path`, anywhere under the scan root, in line
    /// with the disk: adds it, updates its size or removes it, fixing every
    /// ancestor's size and keeping each level sorted. If a directory between
    /// the root and `path` is missing from the tree, the highest missing one
    /// is reconciled instead. Paths outside the root, and the root itself,
    /// are ignored.
    public func reconcile(_ path: String) {
        guard let names = relativeNames(path), let name = names.last else { return }
        let parents = Array(names.dropLast())
        let known = knownDepth(parents)
        if known < parents.count {
            reconcile(self.path(for: names[...known]))
            return
        }
        guard let parent = directory(at: parents[...]) else { return }
        let full = self.path(for: names[...])

        guard let st = lstatInfo(full), st.st_mode & S_IFMT != S_IFLNK else {
            // Gone, or a symlink (which the scanner skips).
            replaceChild(named: name, in: parent, with: nil)
            return
        }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            if !parent.children.contains(where: { $0.isDirectory && $0.name == name }) {
                // Show it right away, then fill in its size from a full scan.
                replaceChild(named: name, in: parent, with: FileNode(name: name, isDirectory: true))
                scanInBackground(full)
            }
        case S_IFREG:
            replaceChild(named: name, in: parent, with: FileNode(name: name, size: diskUsage(st), isDirectory: false))
        default:
            replaceChild(named: name, in: parent, with: FileNode(name: name, size: 0, isDirectory: false))
        }
    }

    /// Events were dropped for `path`: rescans the deepest directory the tree
    /// knows on that path (the scan root if `path` is outside it).
    public func rescan(_ path: String) {
        let form = scanPathForm(path)
        guard Self.isWithin(form, scanPath) else {
            scanInBackground(scanPath)
            return
        }
        // nil: inside an excluded directory, nothing to do.
        guard let names = relativeNames(path) else { return }
        let depth = knownDepth(names)
        scanInBackground(self.path(for: names[..<depth]))
    }

    /// Removes `node` (after it was trashed, say) and fixes the sizes above.
    public func remove(_ node: FileNode) {
        guard node !== root, let parent = node.parent, isAttached(node) else { return }
        replaceChild(named: node.name, in: parent, with: nil)
    }

    /// Renames `node` in place (after it was renamed on disk).
    public func rename(_ node: FileNode, to newName: String) {
        guard node !== root, isAttached(node) else { return }
        node.name = newName
        version &+= 1
    }

    /// Scans the whole tree again in the background, keeping focus and
    /// selection where they were (by path).
    public func rescanAll() {
        scanInBackground(scanPath)
    }

    /// Waits until no background scan is running (for tests).
    public func waitForBackgroundScans() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    // MARK: Background scans

    /// Scans the directory `path` off the main actor and puts the result in
    /// the tree. If it, or a directory above it, is already being scanned,
    /// that scan is marked to run again when it finishes.
    func scanInBackground(_ path: String) {
        var dir = path
        while true {
            if pendingScans[dir] != nil {
                pendingScans[dir]!.changed = true
                return
            }
            guard dir != "/", let slash = dir.lastIndex(of: "/") else { break }
            dir = slash == dir.startIndex ? "/" : String(dir[..<slash])
        }
        // This scan supersedes any running below it.
        for (other, entry) in pendingScans where Self.isWithin(other, path) {
            pendingScans[other] = nil
            tasks[entry.id]?.cancel()
            tasks[entry.id] = nil
        }
        nextScanID &+= 1
        let id = nextScanID
        pendingScans[path] = (id, false)
        let scanner = self.scanner
        tasks[id] = Task { [weak self] in
            let node = try? await scanner.scan(path: path)
            self?.finishBackgroundScan(path: path, id: id, node: node)
        }
    }

    private func finishBackgroundScan(path: String, id: UInt64, node: FileNode?) {
        tasks[id] = nil
        guard let entry = pendingScans[path], entry.id == id else { return }
        pendingScans[path] = nil
        if let node { applyScannedDirectory(path: path, node: node) }
        if entry.changed { scanInBackground(path) }
    }

    /// Puts a finished scan of `path` into the tree, if the directory is
    /// still on disk and its parent is in the tree.
    private func applyScannedDirectory(path: String, node: FileNode) {
        guard let names = relativeNames(path) else { return }
        guard let st = lstatInfo(path), st.st_mode & S_IFMT == S_IFDIR else {
            // Gone or replaced since; its own event handles that.
            return
        }
        guard let name = names.last else {
            // The whole tree was rescanned.
            node.name = root.name
            let oldRoot = root
            let newFocus = Self.follow(oldRoot, to: focus, in: node)
            let newSelection = selection.flatMap { Self.follow(oldRoot, to: $0, in: node, exact: true) }
            root = node
            focus = newFocus ?? node
            selection = newSelection
            version &+= 1
            return
        }
        node.name = name
        guard let parent = directory(at: names.dropLast()) else { return }
        replaceChild(named: name, in: parent, with: node)
    }

    // MARK: Tree edits

    /// Replaces (or with nil, removes) the child `name` of `parent`, keeping
    /// sizes and order right up to the root and focus and selection valid.
    private func replaceChild(named name: String, in parent: FileNode, with new: FileNode?) {
        let oldIndex = parent.children.firstIndex { $0.name == name }
        let old = oldIndex.map { parent.children[$0] }
        if old == nil && new == nil { return }

        // Move focus and selection off the old subtree before it is freed.
        if let old {
            if Self.isDescendant(focus, of: old) {
                focus = new.flatMap { $0.isDirectory ? Self.follow(old, to: focus, in: $0) : nil } ?? parent
            }
            if let selected = selection, Self.isDescendant(selected, of: old) {
                selection = new.flatMap { Self.follow(old, to: selected, in: $0, exact: true) }
            }
        }

        let oldSize = old?.size ?? 0
        let newSize = new?.size ?? 0
        if let oldIndex { parent.children.remove(at: oldIndex) }
        if let new {
            new.parent = parent
            parent.insertSorted(new)
        }
        // Fix sizes and order on the way up.
        var node: FileNode? = parent
        while let current = node {
            let before = current.size
            current.size = current.size &- min(oldSize, current.size) &+ newSize
            if let up = current.parent, before != current.size {
                up.reposition(current)
            }
            node = current.parent
        }
        version &+= 1
    }

    // MARK: Paths

    /// `path` rewritten to start with `scanPath` if it is under the
    /// canonical form instead; otherwise unchanged.
    func scanPathForm(_ path: String) -> String {
        let path = DiskScanner.normalize(path)
        if !Self.isWithin(path, scanPath), Self.isWithin(path, canonicalPath) {
            return scanPath + String(path.dropFirst(canonicalPath.count))
        }
        return path
    }

    /// Names from the scan root to `path` (empty for the root), or nil if
    /// `path` is outside the root or inside an excluded directory.
    func relativeNames(_ path: String) -> [String]? {
        let path = scanPathForm(path)
        guard Self.isWithin(path, scanPath) else { return nil }
        let names = path == scanPath ? [] : DiskScanner.components(of: path, below: scanPath)
        // The scanner keeps excluded directories empty.
        if !scanner.excluded.isEmpty {
            var dir = scanPath
            for name in names.dropLast() {
                dir = DiskScanner.join(dir, name)
                if scanner.excluded.contains(dir) { return nil }
            }
        }
        return names
    }

    func path<C: Collection>(for names: C) -> String where C.Element == String {
        names.reduce(scanPath) { DiskScanner.join($0, $1) }
    }

    /// The directory node at `names` below the root, if the tree has it.
    func directory<C: Collection>(at names: C) -> FileNode? where C.Element == String {
        var node = root
        for name in names {
            guard let next = node.children.first(where: { $0.isDirectory && $0.name == name }) else {
                return nil
            }
            node = next
        }
        return node
    }

    /// How many leading `names` the tree has as nested directories.
    func knownDepth(_ names: [String]) -> Int {
        var node = root
        for (depth, name) in names.enumerated() {
            guard let next = node.children.first(where: { $0.isDirectory && $0.name == name }) else {
                return depth
            }
            node = next
        }
        return names.count
    }

    /// Whether `node` is (still) in this tree. Only pass nodes that are
    /// alive with their ancestors: the focus, the selection, or nodes from
    /// the current tree.
    public func isAttached(_ node: FileNode) -> Bool {
        var current = node
        while let parent = current.parent {
            guard parent.children.contains(where: { $0 === current }) else { return false }
            current = parent
        }
        return current === root
    }

    static func isWithin(_ path: String, _ base: String) -> Bool {
        path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    static func isDescendant(_ node: FileNode, of ancestor: FileNode) -> Bool {
        var current: FileNode? = node
        while let c = current {
            if c === ancestor { return true }
            current = c.parent
        }
        return false
    }

    /// The node in `newSubtree` at the same names below it as `target` is
    /// below `oldSubtree`: as deep as the new subtree goes, or (with `exact`)
    /// only the exact match.
    static func follow(_ oldSubtree: FileNode, to target: FileNode, in newSubtree: FileNode, exact: Bool = false) -> FileNode? {
        var names: [String] = []
        var current = target
        while current !== oldSubtree {
            names.append(current.name)
            guard let parent = current.parent else { return nil }
            current = parent
        }
        var node = newSubtree
        for name in names.reversed() {
            guard let next = node.children.first(where: { $0.name == name }) else {
                return exact ? nil : node
            }
            node = next
        }
        return node
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

extension FileNode {
    /// Inserts `child` keeping children sorted by size, largest first.
    func insertSorted(_ child: FileNode) {
        var low = 0
        var high = children.count
        while low < high {
            let mid = (low + high) / 2
            if children[mid].size >= child.size { low = mid + 1 } else { high = mid }
        }
        children.insert(child, at: low)
    }

    /// Moves `child`, whose size changed, to its sorted place.
    func reposition(_ child: FileNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        insertSorted(child)
    }
}
