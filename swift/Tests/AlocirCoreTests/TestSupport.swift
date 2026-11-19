import Darwin
import Foundation
import Testing
@testable import AlocirCore

/// A temporary directory removed when the value is dropped.
final class TempTree {
    let root: String

    init(_ label: String = #function) {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let safe = label.filter { $0.isLetter || $0.isNumber }
        root = base + "/alocir-\(safe)-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    func dir(_ relative: String) {
        try! FileManager.default.createDirectory(
            atPath: path(relative), withIntermediateDirectories: true)
    }

    func file(_ relative: String, bytes: Int, fill: UInt8 = 0) {
        let data = Data(repeating: fill, count: bytes)
        #expect(FileManager.default.createFile(atPath: path(relative), contents: data))
    }

    /// A file `length` bytes long with (almost) nothing allocated.
    func sparse(_ relative: String, length: Int64) {
        let fd = open(path(relative), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        precondition(fd >= 0)
        precondition(ftruncate(fd, length) == 0)
        close(fd)
    }

    func hardLink(_ existing: String, _ new: String) {
        precondition(link(path(existing), path(new)) == 0)
    }

    func symlink(_ target: String, _ new: String) {
        precondition(Darwin.symlink(path(target), path(new)) == 0)
    }

    /// Allocated size per `lstat`, as `du` counts it.
    func usage(_ relative: String) -> UInt64 {
        diskUsage(lstatInfo(path(relative))!)
    }
}

extension FileNode {
    func child(_ name: String) -> FileNode? {
        children.first { $0.name == name }
    }
}

func canOpenDirectory(_ path: String) -> Bool {
    if let reader = DirectoryReader(path: path) {
        _ = consume reader
        return true
    }
    return false
}
