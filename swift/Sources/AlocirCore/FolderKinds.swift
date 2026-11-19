/// The kind of file that takes the most space in each folder, so the map can
/// tint a folder by what it holds instead of drawing every folder alike.
public enum FolderKinds {
    /// Dominant kinds for `focus` and the folders below it, down to `levels`
    /// levels (the map's nesting depth): one pass over the subtree, which has
    /// to be read in full for the sums. Folders without any files (or only
    /// empty ones) are left out.
    public static func dominantKinds(below focus: FileNode, levels: Int) -> [ObjectIdentifier: FileKind] {
        var result: [ObjectIdentifier: FileKind] = [:]
        _ = totals(of: focus, depth: 0, levels: levels, into: &result)
        return result
    }

    private static let kindCount = FileKind.allCases.count

    /// Bytes by kind below `folder`, recording the dominant kind of folders
    /// no deeper than `levels`.
    private static func totals(
        of folder: FileNode, depth: Int, levels: Int, into result: inout [ObjectIdentifier: FileKind]
    ) -> [UInt64] {
        var bytes = [UInt64](repeating: 0, count: kindCount)
        for child in folder.children {
            if child.isDirectory {
                guard !child.children.isEmpty else { continue }
                let sub = totals(of: child, depth: depth + 1, levels: levels, into: &result)
                for index in 0..<kindCount { bytes[index] &+= sub[index] }
            } else {
                bytes[Int(child.kind.rawValue)] &+= child.size
            }
        }
        if depth <= levels, let kind = dominant(bytes) {
            result[ObjectIdentifier(folder)] = kind
        }
        return bytes
    }

    /// The kind with the most bytes, or `nil` when there are none.
    static func dominant(_ bytes: [UInt64]) -> FileKind? {
        var best: FileKind?
        var bestBytes: UInt64 = 0
        for kind in FileKind.allCases where kind != .directory {
            let value = bytes[Int(kind.rawValue)]
            if value > bestBytes {
                best = kind
                bestBytes = value
            }
        }
        return best
    }
}
