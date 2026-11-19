import Dispatch
import Foundation
import Observation

/// A parsed search query. Tokens are separated by spaces and all must match:
///
/// | Token | Meaning |
/// |---|---|
/// | `report` | Name contains it, ignoring case |
/// | `.mp4` or `*.mp4` | Name ends with that extension |
/// | `>500mb`, `<1gb` | Size above or below (`b`, `kb`, `mb`, `gb`, `tb`) |
///
/// Size tokens only match files: every folder above a big file is big too,
/// which would bury the files in folders.
public struct SearchQuery: Sendable, Equatable {
    public enum Term: Sendable, Equatable {
        case name(String)
        case fileExtension(String)
        case larger(UInt64)
        case smaller(UInt64)
    }

    public let terms: [Term]
    /// Lowercased ASCII bytes of each name or extension term; nil if the
    /// term is not ASCII and needs Foundation's comparison.
    private let asciiBytes: [[UInt8]?]

    /// nil for an empty query.
    public init?(_ text: String) {
        var terms: [Term] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            terms.append(Self.parse(String(token)))
        }
        guard !terms.isEmpty else { return nil }
        self.terms = terms
        self.asciiBytes = terms.map { term in
            switch term {
            case .name(let s), .fileExtension(let s):
                return s.utf8.allSatisfy { $0 < 0x80 } ? s.utf8.map(Self.lowerASCII) : nil
            case .larger, .smaller:
                return nil
            }
        }
    }

    static func parse(_ token: String) -> Term {
        if let first = token.first, first == ">" || first == "<", let size = parseSize(token.dropFirst()) {
            return first == ">" ? .larger(size) : .smaller(size)
        }
        var ext = Substring(token)
        if ext.hasPrefix("*") { ext = ext.dropFirst() }
        if ext.hasPrefix("."), ext.count > 1 {
            return .fileExtension(String(ext.dropFirst()))
        }
        return .name(token)
    }

    /// "500mb", "1.5GB", "200", "10 kb" (no space in practice): bytes.
    static func parseSize(_ text: Substring) -> UInt64? {
        let lower = text.lowercased()
        let units: [(String, Double)] = [
            ("tb", 1_099_511_627_776), ("gb", 1_073_741_824), ("mb", 1_048_576), ("kb", 1024),
            ("t", 1_099_511_627_776), ("g", 1_073_741_824), ("m", 1_048_576), ("k", 1024), ("b", 1),
        ]
        var number = Substring(lower)
        var multiplier = 1.0
        for (suffix, value) in units where lower.hasSuffix(suffix) {
            number = lower.dropLast(suffix.count)
            multiplier = value
            break
        }
        guard let value = Double(number), value >= 0, value.isFinite else { return nil }
        return UInt64(min(value * multiplier, Double(UInt64.max / 2)))
    }

    private static func lowerASCII(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte | 0x20 : byte
    }

    public func matches(_ node: FileNode) -> Bool {
        for (index, term) in terms.enumerated() {
            switch term {
            case .name(let text):
                guard Self.contains(node.name, text, ascii: asciiBytes[index]) else { return false }
            case .fileExtension(let ext):
                guard Self.hasExtension(node.name, ext, ascii: asciiBytes[index]) else { return false }
            case .larger(let size):
                guard !node.isDirectory, node.size > size else { return false }
            case .smaller(let size):
                guard !node.isDirectory, node.size < size else { return false }
            }
        }
        return true
    }

    static func contains(_ name: String, _ text: String, ascii: [UInt8]?) -> Bool {
        guard let needle = ascii else {
            return name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var name = name
        return name.withUTF8 { haystack in
            let n = needle.count
            guard n > 0 else { return true }
            guard haystack.count >= n else { return false }
            let first = needle[0]
            var i = 0
            let last = haystack.count - n
            while i <= last {
                if lowerASCII(haystack[i]) == first {
                    var j = 1
                    while j < n && lowerASCII(haystack[i + j]) == needle[j] { j += 1 }
                    if j == n { return true }
                }
                i += 1
            }
            return false
        }
    }

    static func hasExtension(_ name: String, _ ext: String, ascii: [UInt8]?) -> Bool {
        guard let needle = ascii else {
            guard let dot = name.lastIndex(of: ".") else { return false }
            return name[name.index(after: dot)...].compare(
                ext, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        var name = name
        return name.withUTF8 { bytes in
            let n = needle.count
            guard bytes.count > n + 1 else { return false }
            let start = bytes.count - n
            guard bytes[start - 1] == UInt8(ascii: ".") else { return false }
            for j in 0..<n where lowerASCII(bytes[start + j]) != needle[j] { return false }
            return true
        }
    }
}

/// What a search found.
public struct SearchResult: Sendable {
    /// Matching nodes, in tree order (parents before children).
    public var matches: [FileNode]
    public var count: Int { matches.count }
    /// Total size of the matches, counting a match inside another match once.
    public var totalSize: UInt64
}

/// Bits in `FileNode.searchMark`, so the painter can dim everything else
/// without a lookup.
public enum SearchMark {
    public static let match: UInt8 = 1
    public static let containsMatch: UInt8 = 2
}

/// Runs searches over a `LiveTree` on the main actor, in slices of a few
/// milliseconds, so the UI stays live and no locking is needed against tree
/// edits. Restarts (debounced) when the query or the tree version changes.
@MainActor
@Observable
public final class TreeSearch {
    public private(set) var query: SearchQuery?
    /// The last complete result for `query`; nil when there is no query.
    public private(set) var result: SearchResult?
    public private(set) var isSearching = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var searchedVersion: UInt64?
    @ObservationIgnored let sliceDuration: UInt64
    @ObservationIgnored let debounce: Duration

    public init(debounce: Duration = .milliseconds(150), sliceMilliseconds: UInt64 = 4) {
        self.debounce = debounce
        self.sliceDuration = sliceMilliseconds * 1_000_000
    }

    /// Sets the query text; searches after the debounce delay.
    public func setText(_ text: String, in tree: LiveTree) {
        let query = SearchQuery(text)
        guard query != self.query else { return }
        self.query = query
        restart(tree, debounced: true)
    }

    /// Call when `tree.version` changes; searches again if needed.
    public func treeDidChange(_ tree: LiveTree) {
        guard query != nil, searchedVersion != tree.version else { return }
        restart(tree, debounced: true)
    }

    /// Waits for the running search, if any (for tests).
    public func waitUntilDone() async {
        while let task {
            await task.value
            if self.task == task { break }
        }
    }

    private func restart(_ tree: LiveTree, debounced: Bool) {
        task?.cancel()
        guard let query else {
            task = nil
            isSearching = false
            result = nil
            searchedVersion = nil
            Self.clearMarks(tree.root)
            return
        }
        isSearching = true
        let delay = debounced ? debounce : .zero
        task = Task { [weak self, weak tree] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self, let tree else { return }
            await self.run(query, in: tree)
        }
    }

    private func run(_ query: SearchQuery, in tree: LiveTree) async {
        let version = tree.version
        var matches: [FileNode] = []
        var total: UInt64 = 0
        var stack: [FileNode] = [tree.root]
        tree.root.searchMark = 0
        var sliceEnd = DispatchTime.now().uptimeNanoseconds + sliceDuration
        var visited = 0
        while let node = stack.popLast() {
            for child in node.children.reversed() {
                child.searchMark = 0
                if query.matches(child) {
                    child.searchMark = SearchMark.match
                    matches.append(child)
                    if Self.markAncestors(of: child) { total &+= child.size }
                }
                if !child.children.isEmpty { stack.append(child) }
            }
            visited += node.children.count
            if visited >= 256 {
                visited = 0
                if DispatchTime.now().uptimeNanoseconds >= sliceEnd {
                    await Task.yield()
                    // A cancelled or outdated search stops; a new one runs.
                    if Task.isCancelled || tree.version != version { return }
                    sliceEnd = DispatchTime.now().uptimeNanoseconds + sliceDuration
                }
            }
        }
        guard !Task.isCancelled, tree.version == version else { return }
        result = SearchResult(matches: matches, totalSize: total)
        searchedVersion = version
        isSearching = false
    }

    /// Marks every ancestor of a match. False if one of them is itself a
    /// match (so this match's size is already counted).
    private static func markAncestors(of node: FileNode) -> Bool {
        var counted = true
        var current = node.parent
        while let ancestor = current {
            if ancestor.searchMark & SearchMark.match != 0 { counted = false }
            ancestor.searchMark |= SearchMark.containsMatch
            current = ancestor.parent
        }
        return counted
    }

    static func clearMarks(_ root: FileNode) {
        var stack = [root]
        while let node = stack.popLast() {
            node.searchMark = 0
            stack.append(contentsOf: node.children)
        }
    }
}
