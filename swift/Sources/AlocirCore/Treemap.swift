import CoreGraphics

/// One laid-out tile. `parent` and `subtreeEnd` index into the same tile
/// array: a tile's descendants are exactly `index + 1 ..< subtreeEnd`.
public struct Tile: Sendable {
    public var rect: CGRect
    public var node: FileNode
    /// 0 for children of the focused folder, 1 for theirs, ...
    public var depth: UInt8
    /// A directory tile drawn as a frame with its children inside.
    public var showsChildren: Bool
    /// Index of the enclosing tile, or -1 at depth 0.
    public var parent: Int32
    /// One past the last descendant's index.
    public var subtreeEnd: Int32
}

/// Squarified, nested treemap layout. Pure, and recomputed only when the
/// tree version, the focused folder, the view size or the depth changes.
public struct TreemapLayout: Sendable {
    public struct Options: Sendable, Equatable {
        /// Levels of tiles drawn (1 = just the focused folder's children).
        public var maxDepth: Int = 4
        /// Height of a nested directory's header strip.
        public var headerHeight: CGFloat = 16
        /// Gap between a nested directory's frame and its children.
        public var inset: CGFloat = 2
        /// A directory tile shows its children only when at least this big.
        public var minNestedWidth: CGFloat = 48
        public var minNestedHeight: CGFloat = 40
        /// Rows thinner than this end the layout of a folder: children are
        /// sorted, so nothing after them could be drawn.
        public var minThickness: CGFloat = 1

        public init() {}
    }

    public let tiles: [Tile]
    public let bounds: CGRect
    public let options: Options

    /// Lays out the children of `focus` (sorted by size, as the tree keeps
    /// them) in `bounds`, nesting directories that are big enough.
    public init(focus: FileNode, bounds: CGRect, options: Options = Options()) {
        self.bounds = bounds
        self.options = options
        var tiles: [Tile] = []
        tiles.reserveCapacity(min(focus.children.count * 2, 1 << 16))
        Self.layoutChildren(of: focus, in: bounds, depth: 0, parent: -1, options: options, into: &tiles)
        self.tiles = tiles
    }

    private static func layoutChildren(
        of node: FileNode, in rect: CGRect, depth: Int, parent: Int32, options: Options,
        into tiles: inout [Tile]
    ) {
        let rects = squarify(node.children.lazy.map { Double($0.size) }, in: rect, minThickness: options.minThickness)
        for (i, childRect) in rects.enumerated() {
            let child = node.children[i]
            let index = tiles.count
            let nests = child.isDirectory && !child.children.isEmpty && depth + 1 < options.maxDepth
                && childRect.width >= options.minNestedWidth && childRect.height >= options.minNestedHeight
            tiles.append(Tile(
                rect: childRect, node: child, depth: UInt8(clamping: depth), showsChildren: nests,
                parent: parent, subtreeEnd: Int32(index + 1)))
            if nests {
                let inner = CGRect(
                    x: childRect.minX + options.inset,
                    y: childRect.minY + options.headerHeight,
                    width: childRect.width - 2 * options.inset,
                    height: childRect.height - options.headerHeight - options.inset)
                if inner.width >= 1 && inner.height >= 1 {
                    layoutChildren(
                        of: child, in: inner, depth: depth + 1, parent: Int32(index), options: options,
                        into: &tiles)
                }
                tiles[index].subtreeEnd = Int32(tiles.count)
            }
        }
    }

    // MARK: Squarify

    /// Squarified layout of `sizes` (sorted largest first) in `bounds`.
    /// Returns one rect per laid-out size, in order: zero sizes, and every
    /// size after a row thinner than `minThickness`, are left out.
    public static func squarify<S: Sequence>(_ sizes: S, in bounds: CGRect, minThickness: CGFloat = 0) -> [CGRect]
    where S.Element == Double {
        var values: [Double] = []
        var total = 0.0
        for size in sizes {
            guard size > 0 else { break }
            values.append(size)
            total += size
        }
        guard !values.isEmpty, total > 0, bounds.width > 0, bounds.height > 0 else { return [] }

        let scale = Double(bounds.width) * Double(bounds.height) / total
        var out: [CGRect] = []
        out.reserveCapacity(values.count)

        var x = Double(bounds.minX), y = Double(bounds.minY)
        var w = Double(bounds.width), h = Double(bounds.height)
        var start = 0
        let minThickness = Double(minThickness)

        while start < values.count && w > 0 && h > 0 {
            if start == values.count - 1 {
                out.append(CGRect(x: x, y: y, width: w, height: h))
                break
            }
            // Lay out along the shorter side. Add items to the row until the
            // worst aspect ratio starts to grow; it depends only on the
            // row's largest (first) and smallest (last) areas.
            let horizontal = w >= h
            let side = horizontal ? h : w
            var rowSum = 0.0
            var best = Double.greatestFiniteMagnitude
            var end = start
            let maxArea = values[start] * scale
            while end < values.count {
                let area = values[end] * scale
                let sum = rowSum + area
                let worst = worstRatio(maxArea: maxArea, minArea: area, rowSum: sum, side: side)
                if worst <= best {
                    best = worst
                    rowSum = sum
                    end += 1
                } else {
                    break
                }
            }
            let thickness = rowSum / side
            if thickness < minThickness { break }

            var offset = 0.0
            for i in start..<end {
                let length = values[i] * scale / thickness
                if horizontal {
                    out.append(CGRect(x: x, y: y + offset, width: thickness, height: length))
                } else {
                    out.append(CGRect(x: x + offset, y: y, width: length, height: thickness))
                }
                offset += length
            }
            if horizontal {
                x += thickness
                w -= thickness
            } else {
                y += thickness
                h -= thickness
            }
            start = end
        }
        return out
    }

    /// Worst aspect ratio of a row from its largest and smallest areas: each
    /// item's ratio is max(side² · area / sum², sum² / (side² · area)), which
    /// peaks at one of the extremes.
    static func worstRatio(maxArea: Double, minArea: Double, rowSum: Double, side: Double) -> Double {
        guard rowSum > 0, side > 0 else { return .greatestFiniteMagnitude }
        guard maxArea > 0, minArea > 0 else { return 0 }
        let sideSq = side * side
        let sumSq = rowSum * rowSum
        return max(sideSq * maxArea / sumSq, sumSq / (sideSq * minArea))
    }

    // MARK: Hit testing and moving

    /// The deepest tile containing `point`, or nil.
    public func hitTest(_ point: CGPoint) -> Int? {
        var found: Int?
        var i = 0
        var end = tiles.count
        while i < end {
            let tile = tiles[i]
            if Self.contains(tile.rect, point) {
                found = i
                end = Int(tile.subtreeEnd)
                i += 1
            } else {
                i = Int(tile.subtreeEnd)
            }
        }
        return found
    }

    /// Index of the tile showing `node`, if it is laid out.
    public func index(of node: FileNode) -> Int? {
        tiles.firstIndex { $0.node === node }
    }

    public func parent(of index: Int) -> Int? {
        let parent = Int(tiles[index].parent)
        return parent >= 0 ? parent : nil
    }

    /// The largest child tile of a nested directory tile.
    public func firstChild(of index: Int) -> Int? {
        let next = index + 1
        return next < Int(tiles[index].subtreeEnd) ? next : nil
    }

    public func isAncestor(_ ancestor: Int, of index: Int) -> Bool {
        var current = index
        while current >= 0 {
            if current == ancestor { return true }
            current = Int(tiles[current].parent)
        }
        return false
    }

    public enum Direction: Sendable { case left, right, up, down }

    /// The tile an arrow key moves the selection to: probe just past the
    /// selected tile's edge, take the tile there at the selection's depth,
    /// and keep going while that is the selection or one of its ancestors
    /// (a header strip or gap). Crossing another folder's frame looks for a
    /// tile at the same depth inside it. nil at the edge of the map.
    public func move(from index: Int, direction: Direction) -> Int? {
        let tile = tiles[index]
        let rect = tile.rect
        var probe: CGPoint
        let step: CGVector
        switch direction {
        case .left: probe = CGPoint(x: rect.minX - 0.5, y: rect.midY); step = CGVector(dx: -1, dy: 0)
        case .right: probe = CGPoint(x: rect.maxX + 0.5, y: rect.midY); step = CGVector(dx: 1, dy: 0)
        case .up: probe = CGPoint(x: rect.midX, y: rect.minY - 0.5); step = CGVector(dx: 0, dy: -1)
        case .down: probe = CGPoint(x: rect.midX, y: rect.maxY + 0.5); step = CGVector(dx: 0, dy: 1)
        }
        // A shallower folder frame crossed on the way, used if no tile at the
        // selection's depth turns up beyond it.
        var fallback: Int?
        while Self.contains(bounds, probe) {
            if var hit = hitTest(probe) {
                while tiles[hit].depth > tile.depth, tiles[hit].parent >= 0 {
                    hit = Int(tiles[hit].parent)
                }
                if !isAncestor(hit, of: index) {
                    if let candidate = fallback, !isAncestor(candidate, of: hit) {
                        // Left that folder without finding anything inside.
                        return candidate
                    }
                    if tiles[hit].depth == tile.depth || !tiles[hit].showsChildren {
                        return hit
                    }
                    // The header or frame of another folder: look inside it.
                    if fallback == nil { fallback = hit }
                } else if let candidate = fallback {
                    return candidate
                }
            } else if let candidate = fallback {
                return candidate
            }
            probe.x += step.dx
            probe.y += step.dy
        }
        return fallback
    }

    static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
    }
}
