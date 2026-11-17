import Darwin
import Dispatch
import Synchronization

/// Live figures for a running scan. Safe to read from any thread; the scanner
/// updates the counters once per directory and the path at most every 50 ms.
public final class ScanProgress: Sendable {
    private let items = Atomic<UInt64>(0)
    private let bytes = Atomic<UInt64>(0)
    private let path = Mutex<String>("")
    private let lastPathUpdate = Atomic<UInt64>(0)
    private let cancelled = Atomic<Bool>(false)
    private let started = DispatchTime.now().uptimeNanoseconds

    static let pathUpdateInterval: UInt64 = 50_000_000

    public init() {}

    /// Files and directories counted so far.
    public var itemsScanned: UInt64 { items.load(ordering: .relaxed) }
    /// Allocated bytes counted so far.
    public var bytesScanned: UInt64 { bytes.load(ordering: .relaxed) }
    /// A directory being scanned, refreshed at most every 50 ms.
    public var currentPath: String { path.withLock { $0 } }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Asks the scan to stop. It checks once per directory.
    public func cancel() { cancelled.store(true, ordering: .relaxed) }

    func add(items count: UInt64, bytes size: UInt64) {
        if count > 0 { items.wrappingAdd(count, ordering: .relaxed) }
        if size > 0 { bytes.wrappingAdd(size, ordering: .relaxed) }
    }

    /// Publishes `current` if 50 ms have passed since the last update. Only
    /// one thread wins each interval.
    func offerPath(_ current: @autoclosure () -> String) {
        let now = DispatchTime.now().uptimeNanoseconds &- started
        let last = lastPathUpdate.load(ordering: .relaxed)
        guard now &- last >= Self.pathUpdateInterval else { return }
        guard lastPathUpdate.compareExchange(
            expected: last, desired: now, ordering: .relaxed).exchanged else { return }
        let value = current()
        path.withLock { $0 = value }
    }
}

/// Scans a folder into a `FileNode` tree. Sizes are disk usage, as `du`
/// counts them:
///
/// - Files count their allocated size. A directory is the sum of its
///   children; its own blocks are not counted.
/// - Symlinks are skipped. Sockets, FIFOs and devices are zero-size files.
/// - A file with more than one hard link is counted once per scan.
/// - Every directory is visited once per scan, by `(device, inode)`, which
///   stops firmlinks such as `/Users` being counted twice.
/// - `/System/Volumes/Data` is scanned last when the scan contains it, then
///   grafted in, so data is counted under the familiar paths.
/// - Unreadable directories become empty directories.
public struct Scanner: Sendable {
    /// Directories to leave empty (full paths).
    public var excluded: Set<String>
    /// Scanned last and grafted in; see the type's documentation.
    var deferredVolume = "/System/Volumes/Data"
    /// Read directories with `readdir` + `fstatat` instead of
    /// `getattrlistbulk` (for tests and comparisons).
    public var useFallbackReader = false

    public init(excluded: Set<String> = []) {
        self.excluded = excluded
    }

    private static let queue = DispatchQueue(
        label: "org.opensystemsfoundation.alocir.scan", qos: .userInitiated,
        attributes: .concurrent)

    /// Scans `path` off the cooperative thread pool. Cancelling the calling
    /// task stops the scan and throws `CancellationError`.
    public func scan(path: String, progress: ScanProgress = ScanProgress()) async throws -> FileNode {
        let node = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<FileNode, Never>) in
                Self.queue.async {
                    continuation.resume(returning: self.scanSynchronously(path: path, progress: progress))
                }
            }
        } onCancel: {
            progress.cancel()
        }
        if progress.isCancelled { throw CancellationError() }
        return node
    }

    /// Scans `path` on the calling thread (and Dispatch's worker threads).
    /// Never call this from the main actor or a Swift concurrency task.
    public func scanSynchronously(path: String, progress: ScanProgress = ScanProgress()) -> FileNode {
        let root = Self.normalize(path)
        let state = ScanState()
        let run = Run(scanner: self, progress: progress, state: state, root: root)
        let node = run.scanEntry(path: root, name: root, allowDefer: true)
            ?? FileNode(name: root, isDirectory: true)
        // Now that everything else is counted, scan what was put off.
        for dir in state.takeDeferred() {
            let components = Self.components(of: dir, below: root)
            guard !components.isEmpty, node.isDirectory,
                let sub = run.scanEntry(path: dir, name: components.last!, allowDefer: false)
            else { continue }
            node.graft(components[...], sub)
        }
        return node
    }

    static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    /// Names of the path components of `path` below `root`.
    static func components(of path: String, below root: String) -> [String] {
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return [] }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }
}

/// Sets shared by every thread of one scan. Locked once per directory and
/// once per hard-linked file.
final class ScanState: Sendable {
    private let visitedDirectories = Mutex<Set<FileID>>([])
    private let countedLinks = Mutex<Set<FileID>>([])
    private let deferred = Mutex<[String]>([])

    /// True the first time a directory is seen.
    func visit(_ id: FileID) -> Bool {
        visitedDirectories.withLock { $0.insert(id).inserted }
    }

    /// True the first time a hard-linked file is seen.
    func countLink(_ id: FileID) -> Bool {
        countedLinks.withLock { $0.insert(id).inserted }
    }

    func addDeferred(_ path: String) {
        deferred.withLock { $0.append(path) }
    }

    func takeDeferred() -> [String] {
        deferred.withLock { list in
            defer { list.removeAll() }
            return list
        }
    }
}

/// One scan's context, shared by its worker threads.
private struct Run: Sendable {
    let scanner: Scanner
    let progress: ScanProgress
    let state: ScanState
    let root: String

    /// Size of a regular file, or 0 if it is another link to a file this scan
    /// already counted.
    func usage(size: UInt64, linkCount: UInt32, id: FileID) -> UInt64 {
        if linkCount > 1 && !state.countLink(id) { return 0 }
        return size
    }

    /// Scans one entry by path. `nil` for a directory that is skipped here:
    /// already visited through another path, or put off until later.
    func scanEntry(path: String, name: String, allowDefer: Bool) -> FileNode? {
        if progress.isCancelled {
            return FileNode(name: name, isDirectory: true)
        }
        if scanner.excluded.contains(path) {
            return FileNode(name: name, isDirectory: true)
        }
        if allowDefer && path != root && path == scanner.deferredVolume {
            state.addDeferred(path)
            return nil
        }

        guard let reader = DirectoryReader(path: path) else {
            return scanNonDirectory(path: path, name: name)
        }
        guard state.visit(reader.id) else { return nil }
        progress.offerPath(path)

        var children: [FileNode] = []
        var subdirectories: [String] = []
        var fileCount: UInt64 = 0
        var fileBytes: UInt64 = 0
        reader.forEachEntry(forceFallback: scanner.useFallbackReader) { entry in
            switch entry.type {
            case .directory:
                subdirectories.append(entry.name)
            case .symlink:
                break
            case .regular:
                let size = usage(size: entry.allocatedSize, linkCount: entry.linkCount, id: entry.id)
                fileCount += 1
                fileBytes += size
                children.append(FileNode(name: entry.name, size: size, isDirectory: false))
            case .special:
                fileCount += 1
                children.append(FileNode(name: entry.name, size: 0, isDirectory: false))
            case .unreadable:
                children.append(FileNode(name: entry.name, size: 0, isDirectory: false))
            }
        }
        // The directory itself counts as one item, as in the Rust app.
        progress.add(items: fileCount + 1, bytes: fileBytes)

        if subdirectories.count == 1 {
            if let node = scanEntry(
                path: Scanner.join(path, subdirectories[0]), name: subdirectories[0],
                allowDefer: allowDefer)
            {
                children.append(node)
            }
        } else if !subdirectories.isEmpty {
            let results = UnsafeMutableBufferPointer<FileNode?>.allocate(capacity: subdirectories.count)
            results.initialize(repeating: nil)
            defer {
                _ = results.deinitialize()
                results.deallocate()
            }
            // Each iteration writes only its own slot.
            nonisolated(unsafe) let slots = results
            let names = subdirectories
            let run = self
            DispatchQueue.concurrentPerform(iterations: names.count) { index in
                slots[index] = run.scanEntry(
                    path: Scanner.join(path, names[index]), name: names[index],
                    allowDefer: allowDefer)
            }
            children.reserveCapacity(children.count + names.count)
            for case let node? in results {
                children.append(node)
            }
        }
        return FileNode(name: name, isDirectory: true, children: children)
    }

    /// What is at `path` when it cannot be opened as a directory: a file, a
    /// symlink, or an unreadable directory.
    private func scanNonDirectory(path: String, name: String) -> FileNode? {
        guard let st = lstatInfo(path) else {
            return FileNode(name: name, size: 0, isDirectory: false)
        }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            return FileNode(name: name, size: 0, isDirectory: false)
        case S_IFREG:
            let size = usage(size: diskUsage(st), linkCount: UInt32(st.st_nlink), id: fileID(st))
            progress.add(items: 1, bytes: size)
            return FileNode(name: name, size: size, isDirectory: false)
        case S_IFDIR:
            // Unreadable directory (EACCES, EPERM...): counted, but empty.
            guard state.visit(fileID(st)) else { return nil }
            progress.add(items: 1, bytes: 0)
            return FileNode(name: name, isDirectory: true)
        default:
            progress.add(items: 1, bytes: 0)
            return FileNode(name: name, size: 0, isDirectory: false)
        }
    }
}

extension Scanner {
    /// Scans one directory with existing shared state (tests only).
    func scanEntryForTesting(path: String, state: ScanState, progress: ScanProgress) -> FileNode? {
        Run(scanner: self, progress: progress, state: state, root: path)
            .scanEntry(path: path, name: path, allowDefer: true)
    }
}
