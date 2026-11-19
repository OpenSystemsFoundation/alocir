/// One file or directory in a scanned tree.
///
/// Thread-safety rule (why `@unchecked Sendable` is sound): a subtree is built
/// by the scanner off the main actor, handed over exactly once, and from then
/// on read and mutated on the main actor only. Never touch a node from two
/// threads after the hand-over.
///
/// `children` is always sorted by size, largest first. The treemap layout
/// depends on it.
///
/// `parent` is `unowned(unsafe)`: whoever owns a tree must keep its root alive
/// while any node in it is used. The root of a scan is named by the full scan
/// path (for example `/Users/me`), so `path` works without other context.
public final class FileNode: @unchecked Sendable {
    public internal(set) var name: String
    /// Allocated bytes. For a directory, the sum of its children.
    public internal(set) var size: UInt64
    /// Sorted by size, descending.
    public internal(set) var children: [FileNode]
    public internal(set) unowned(unsafe) var parent: FileNode?
    public let isDirectory: Bool
    public let kind: FileKind
    /// Bit flags set by search (see `Search.swift`).
    public var searchMark: UInt8 = 0

    /// Builds a node. For a directory with `children`, the size is the sum of
    /// the children, the children are sorted and their parent is set.
    /// A file's kind defaults to the one its name's extension gives.
    public init(
        name: String,
        size: UInt64 = 0,
        isDirectory: Bool,
        kind: FileKind? = nil,
        children: [FileNode] = []
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.kind = kind ?? (isDirectory ? .directory : FileKind(fileName: name))
        if isDirectory {
            var sorted = children
            sorted.sort { $0.size > $1.size }
            self.children = sorted
            self.size = children.isEmpty ? size : children.reduce(0) { $0 + $1.size }
        } else {
            self.children = []
            self.size = size
        }
        for child in self.children {
            child.parent = self
        }
    }

    /// Path components from the root down to this node, root first.
    public var pathComponents: [String] {
        var parts: [String] = []
        var node: FileNode? = self
        while let current = node {
            parts.append(current.name)
            node = current.parent
        }
        return parts.reversed()
    }

    /// The full path, assuming the root's name is the absolute scan path.
    public var path: String {
        var parts = pathComponents
        guard !parts.isEmpty else { return "" }
        let root = parts.removeFirst()
        guard !parts.isEmpty else { return root }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return base + "/" + parts.joined(separator: "/")
    }

    /// Number of nodes in this subtree, including this one.
    public var nodeCount: Int {
        var count = 0
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            count += 1
            stack.append(contentsOf: node.children)
        }
        return count
    }

    /// Inserts `node` at `components` (names below this node, the last being
    /// `node`'s own), adding its size to every directory on the way and
    /// keeping each level sorted. Missing directories are created.
    func graft(_ components: ArraySlice<String>, _ node: FileNode) {
        size += node.size
        if components.count <= 1 {
            node.parent = self
            children.append(node)
        } else {
            let first = components[components.startIndex]
            let next: FileNode
            if let existing = children.first(where: { $0.isDirectory && $0.name == first }) {
                next = existing
            } else {
                next = FileNode(name: first, isDirectory: true)
                next.parent = self
                children.append(next)
            }
            next.graft(components.dropFirst(), node)
        }
        children.sort { $0.size > $1.size }
    }
}
