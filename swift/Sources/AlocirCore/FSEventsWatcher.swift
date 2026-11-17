import CoreServices
import Dispatch
import Foundation
import Synchronization

/// One recursive FSEvents stream on a folder, delivered as an `AsyncStream`
/// of batches.
///
/// File-level events, about 0.3 s latency, on a dispatch queue. Paths in a
/// batch are deduplicated. Events that mean "something was missed"
/// (`MustScanSubDirs`, `UserDropped`, `KernelDropped`, `RootChanged`) become
/// rescans.
public final class FSEventsWatcher: Sendable {
    public struct Batch: Sendable, Equatable {
        /// Paths whose entries may have changed, each once.
        public var paths: [String]
        /// Directories whose contents must be read again.
        public var rescans: [String]

        public init(paths: [String] = [], rescans: [String] = []) {
            self.paths = paths
            self.rescans = rescans
        }
    }

    public let batches: AsyncStream<Batch>
    private let state: Mutex<State>

    private struct State: ~Copyable {
        var stream: FSEventStreamRef?
        var box: Unmanaged<Box>?
    }

    /// Holds the continuation for the C callback.
    private final class Box: Sendable {
        let continuation: AsyncStream<Batch>.Continuation
        init(_ continuation: AsyncStream<Batch>.Continuation) { self.continuation = continuation }
    }

    private static let queue = DispatchQueue(label: "org.opensystemsfoundation.alocir.fsevents")

    /// Starts watching `path` recursively. nil if the stream cannot start.
    public init?(path: String, latency: Double = 0.3) {
        let (batches, continuation) = AsyncStream.makeStream(of: Batch.self, bufferingPolicy: .unbounded)
        let box = Unmanaged.passRetained(Box(continuation))
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, [path] as CFArray,
            FSEventStreamEventId(truncatingIfNeeded: kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            box.release()
            continuation.finish()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
            continuation.finish()
            return nil
        }
        self.batches = batches
        self.state = Mutex(State(stream: stream, box: box))
    }

    deinit { stop() }

    /// Stops the stream and finishes `batches`. Safe to call more than once.
    public func stop() {
        let (stream, box) = state.withLock { state -> (FSEventStreamRef?, Unmanaged<Box>?) in
            defer { state.stream = nil; state.box = nil }
            return (state.stream, state.box)
        }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if let box {
            // Wait for a callback already running on the queue to finish.
            Self.queue.sync {}
            box.takeUnretainedValue().continuation.finish()
            box.release()
        }
    }

    static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    /// Marks the end of replayed history; not a change.
    static let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)

    /// Turns raw events into a batch: dedupes paths, maps the "missed
    /// events" flags to rescans.
    static func makeBatch(paths: [String], flags: [FSEventStreamEventFlags]) -> Batch {
        var batch = Batch()
        var seen = Set<String>()
        var seenRescans = Set<String>()
        for (path, flag) in zip(paths, flags) {
            let path = DiskScanner.normalize(path)
            if flag & rescanFlags != 0 {
                if seenRescans.insert(path).inserted { batch.rescans.append(path) }
            } else if flag & historyDone == 0 {
                if seen.insert(path).inserted { batch.paths.append(path) }
            }
        }
        return batch
    }

    nonisolated(unsafe) private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
        let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var paths: [String] = []
        var flags: [FSEventStreamEventFlags] = []
        paths.reserveCapacity(count)
        flags.reserveCapacity(count)
        for i in 0..<count {
            paths.append(String(cString: cPaths[i]))
            flags.append(eventFlags[i])
        }
        let batch = makeBatch(paths: paths, flags: flags)
        if !batch.paths.isEmpty || !batch.rescans.isEmpty {
            box.continuation.yield(batch)
        }
    }
}
