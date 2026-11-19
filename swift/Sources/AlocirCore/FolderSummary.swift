/// What a folder holds: bytes and file counts by kind (the inspector's
/// breakdown, which doubles as the colour legend) and its largest files.
public struct FolderSummary: Sendable {
    public struct KindTotal: Sendable, Equatable {
        public var kind: FileKind
        public var bytes: UInt64
        public var files: Int
    }

    /// Kinds with at least one file, largest first.
    public var kinds: [KindTotal]
    /// The largest files anywhere below the folder, largest first.
    public var largestFiles: [FileNode]
    public var fileCount: Int
    public var folderCount: Int

    /// One pass over the subtree.
    public init(of folder: FileNode, largest limit: Int = 20) {
        var bytes = [UInt64](repeating: 0, count: 256)
        var counts = [Int](repeating: 0, count: 256)
        var largest: [FileNode] = []
        var files = 0
        var folders = 0
        var stack: [FileNode] = [folder]
        while let node = stack.popLast() {
            for child in node.children {
                if child.isDirectory {
                    folders += 1
                    if !child.children.isEmpty { stack.append(child) }
                    continue
                }
                files += 1
                let k = Int(child.kind.rawValue)
                bytes[k] &+= child.size
                counts[k] += 1
                if largest.count < limit || child.size > largest[largest.count - 1].size {
                    // Keep `largest` sorted, largest first; it stays short.
                    var i = largest.count
                    while i > 0 && largest[i - 1].size < child.size { i -= 1 }
                    largest.insert(child, at: i)
                    if largest.count > limit { largest.removeLast() }
                }
            }
        }
        kinds = FileKind.allCases.compactMap { kind in
            let k = Int(kind.rawValue)
            return counts[k] > 0 ? KindTotal(kind: kind, bytes: bytes[k], files: counts[k]) : nil
        }.sorted { $0.bytes > $1.bytes }
        largestFiles = largest
        fileCount = files
        folderCount = folders
    }
}
