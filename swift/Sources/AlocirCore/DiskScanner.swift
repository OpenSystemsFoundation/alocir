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

    /// Fixed figures, for previews and screenshots.
    public convenience init(items: UInt64, bytes: UInt64, currentPath: String) {
        self.init()
        add(items: items, bytes: bytes)
        path.withLock { $0 = currentPath }
    }

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
public struct DiskScanner: Sendable {
    /// Directories to leave empty (full paths).
    public var excluded: Set<String>
    /// Scanned last and grafted in; see the type's documentation.
    var deferredVolume = "/System/Volumes/Data"
    /// Read directories with `readdir` + `fstatat` instead of
    /// `getattrlistbulk` (for tests and comparisons).
    public var useFallbackReader = false
    /// Open subdirectories relative to their open parent (`openat`) instead
    /// of by full path. Off only to compare the two in tests.
    var opensRelativeToParent = true

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
    /// Parent directories this scan holds open (`DirectoryHandle`). Zero
    /// again once the scan returns.
    let openHandles = Atomic<Int>(0)
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

    /// Directory nodes that turned out not to be read as directories, and
    /// what stands in for each (`nil`: leave it out). Rare, so one lock.
    private let replaced = Mutex<[ObjectIdentifier: FileNode?]>([:])

    func replace(_ node: FileNode, with replacement: FileNode?) {
        replaced.withLock { $0[ObjectIdentifier(node)] = .some(replacement) }
    }

    func takeReplacements() -> [ObjectIdentifier: FileNode?] {
        replaced.withLock { map in
            defer { map.removeAll() }
            return map
        }
    }
}

/// A directory waiting to be scanned. Its node is already in its parent's
/// `children`; the worker that scans the job fills in the node's children,
/// and `finish` sums and sorts once every worker is done. Freed as soon as it
/// has been scanned, so only pending directories cost a job.
private final class DirectoryJob: @unchecked Sendable {
    let path: String
    let node: FileNode
    /// The open parent directory, to open this one relative to. Released as
    /// soon as this job has opened its directory.
    var parent: DirectoryHandle?

    init(path: String, node: FileNode, parent: DirectoryHandle? = nil) {
        self.path = path
        self.node = node
        self.parent = parent
    }
}

/// One worker's pending directories. The owner pushes and pops at the back,
/// so it goes depth first through folders it has just looked up; an idle
/// worker steals from the front, the oldest and usually largest job, so
/// workers spread out over different parts of the tree (as rayon does).
private final class WorkerStack: Sendable {
    private struct Items: Sendable {
        var jobs: [DirectoryJob] = []
        /// Index of the oldest job not yet stolen.
        var head = 0
    }

    private let items = Mutex(Items())

    func push(_ jobs: [DirectoryJob]) {
        items.withLock { $0.jobs.append(contentsOf: jobs) }
    }

    func popNewest() -> DirectoryJob? {
        items.withLock { items in
            guard items.jobs.count > items.head else { return nil }
            let job = items.jobs.removeLast()
            if items.jobs.count == items.head {
                items.jobs.removeAll(keepingCapacity: true)
                items.head = 0
            }
            return job
        }
    }

    func stealOldest() -> DirectoryJob? {
        items.withLock { items in
            guard items.jobs.count > items.head else { return nil }
            let job = items.jobs[items.head]
            items.head += 1
            // Drop stolen slots once they are half the array.
            if items.head > 64 && items.head * 2 > items.jobs.count {
                items.jobs.removeFirst(items.head)
                items.head = 0
            }
            return job
        }
    }
}

/// The directories of one scan, split over its workers.
private final class JobPool: Sendable {
    private let stacks: [WorkerStack]
    /// Jobs pushed and not yet finished. Zero means the scan is done.
    private let pending = Atomic<Int>(0)

    init(workers: Int) {
        stacks = (0..<workers).map { _ in WorkerStack() }
    }

    var workers: Int { stacks.count }

    func push(_ jobs: [DirectoryJob], worker: Int) {
        guard !jobs.isEmpty else { return }
        pending.wrappingAdd(jobs.count, ordering: .relaxed)
        stacks[worker].push(jobs)
    }

    /// Marks a job finished. Call after pushing its subdirectories, so
    /// `pending` never reaches zero while work remains.
    func finish() {
        pending.wrappingSubtract(1, ordering: .releasing)
    }

    /// The next job for `worker`, or `nil` once every job has finished.
    func next(worker: Int) -> DirectoryJob? {
        var idle = 0
        while true {
            if let job = stacks[worker].popNewest() { return job }
            for offset in 1..<max(stacks.count, 1) {
                if let job = stacks[(worker + offset) % stacks.count].stealOldest() { return job }
            }
            if pending.load(ordering: .acquiring) == 0 { return nil }
            // Nothing to steal yet: another worker is reading a directory
            // whose subdirectories will be pushed shortly.
            idle += 1
            if idle < 32 {
                continue
            } else if idle < 128 {
                sched_yield()
            } else {
                usleep(100)
            }
        }
    }
}

/// One scan's context, shared by its worker threads.
private struct Run: Sendable {
    let scanner: DiskScanner
    let progress: ScanProgress
    let state: ScanState
    let root: String

    /// Worker threads per scan: one per active CPU core, or `ALOCIR_SCAN_THREADS`
    /// (for benchmarking).
    static let workerCount: Int = {
        if let value = getenv("ALOCIR_SCAN_THREADS"), let count = Int(String(cString: value)), count > 0 {
            return count
        }
        return max(1, sysconf(_SC_NPROCESSORS_ONLN))
    }()

    /// Size of a regular file, or 0 if it is another link to a file this scan
    /// already counted.
    func usage(size: UInt64, linkCount: UInt32, id: FileID) -> UInt64 {
        if linkCount > 1 && !state.countLink(id) { return 0 }
        return size
    }

    /// Scans `path` and everything below it. `nil` for a directory that is
    /// skipped here: already visited through another path, or put off until
    /// later.
    ///
    /// A fixed set of workers, one per core, each with its own stack of
    /// directories and stealing from the others when idle (see `JobPool`).
    /// Nested `concurrentPerform` calls, which this replaced, narrow to one
    /// thread below the first level and left most cores idle.
    func scanEntry(path: String, name: String, allowDefer: Bool) -> FileNode? {
        let top = DirectoryJob(path: path, node: FileNode(name: name, isDirectory: true))
        let pool = JobPool(workers: Self.workerCount)
        pool.push([top], worker: 0)
        let run = self
        DispatchQueue.concurrentPerform(iterations: pool.workers) { worker in
            while let job = pool.next(worker: worker) {
                run.scan(job, allowDefer: allowDefer, pool: pool, worker: worker)
                pool.finish()
            }
        }
        return Self.finish(top.node, replacements: state.takeReplacements())
    }

    /// Reads one directory into its node: files as they are, subdirectories
    /// as empty nodes, each pushed as a new job.
    private func scan(_ job: DirectoryJob, allowDefer: Bool, pool: JobPool, worker: Int) {
        let name = job.node.name
        // Cancelled or excluded: the node stays an empty directory.
        if progress.isCancelled || scanner.excluded.contains(job.path) {
            return
        }
        if allowDefer && job.path != root && job.path == scanner.deferredVolume {
            state.addDeferred(job.path)
            state.replace(job.node, with: nil)
            return
        }
        let opened = job.parent.flatMap { DirectoryReader(in: $0, name: name) }
            ?? DirectoryReader(path: job.path)
        job.parent = nil
        guard let reader = opened else {
            state.replace(job.node, with: scanNonDirectory(path: job.path, name: name))
            return
        }
        guard state.visit(reader.id) else {
            state.replace(job.node, with: nil)
            return
        }
        progress.offerPath(job.path)

        var children: [FileNode] = []
        var subdirectories: [DirectoryJob] = []
        var fileCount: UInt64 = 0
        var fileBytes: UInt64 = 0
        let path = job.path
        // Kept open while subdirectory jobs still need it; released at the end
        // of this function if there are none.
        let handle = scanner.opensRelativeToParent ? reader.handle(for: state) : nil
        reader.forEachEntry(forceFallback: scanner.useFallbackReader) { entry in
            switch entry.type {
            case .directory:
                let node = FileNode(name: entry.name, isDirectory: true)
                children.append(node)
                subdirectories.append(DirectoryJob(
                    path: DiskScanner.join(path, entry.name), node: node, parent: handle))
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
        // Written before the subdirectory jobs are pushed; each of those
        // writes only its own node.
        job.node.children = children
        pool.push(subdirectories, worker: worker)
    }

    /// Completes the tree once every worker is done: applies replacements,
    /// sets parents, sums sizes and sorts children, largest first. `nil` if
    /// the top directory itself was left out.
    private static func finish(_ top: FileNode, replacements: [ObjectIdentifier: FileNode?]) -> FileNode? {
        if let replacement = replacements[ObjectIdentifier(top)] {
            return replacement
        }
        finishDirectory(top, replacements)
        return top
    }

    private static func finishDirectory(_ node: FileNode, _ replacements: [ObjectIdentifier: FileNode?]) {
        if !replacements.isEmpty
            && node.children.contains(where: { $0.isDirectory && replacements[ObjectIdentifier($0)] != nil })
        {
            node.children = node.children.compactMap { child in
                if let replacement = replacements[ObjectIdentifier(child)] { return replacement }
                return child
            }
        }
        var total: UInt64 = 0
        for child in node.children {
            if child.isDirectory {
                finishDirectory(child, replacements)
            }
            child.parent = node
            total += child.size
        }
        node.children.sort { $0.size > $1.size }
        node.size = total
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

extension DiskScanner {
    /// Scans one directory with existing shared state (tests only).
    func scanEntryForTesting(path: String, state: ScanState, progress: ScanProgress) -> FileNode? {
        Run(scanner: self, progress: progress, state: state, root: path)
            .scanEntry(path: path, name: path, allowDefer: true)
    }
}
