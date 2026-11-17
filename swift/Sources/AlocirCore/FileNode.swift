/// One file or directory in a scanned tree.
///
/// Thread-safety rule (why `@unchecked Sendable` is sound): a subtree is built
/// by the scanner off the main actor, handed over exactly once, and from then
/// on read and mutated on the main actor only. Never touch a node from two
/// threads after the hand-over.
///
/// `children` is always sorted by size, largest first. The treemap layout
/// depends on it.
public final class FileNode: @unchecked Sendable {
    public let name: String
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
    public init(
        name: String,
        size: UInt64 = 0,
        isDirectory: Bool,
        kind: FileKind? = nil,
        children: [FileNode] = []
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.kind = kind ?? (isDirectory ? .directory : .other)
        if isDirectory {
            self.children = children.sorted { $0.size > $1.size }
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
}
