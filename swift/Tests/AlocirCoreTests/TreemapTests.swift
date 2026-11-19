import CoreGraphics
import Foundation
import Testing
@testable import AlocirCore

@Suite struct SquarifyTests {
    private func area(_ r: CGRect) -> Double { Double(r.width) * Double(r.height) }
    private let square = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func emptyInputAndZeroBounds() {
        #expect(TreemapLayout.squarify([Double](), in: square).isEmpty)
        #expect(TreemapLayout.squarify([100.0], in: CGRect(x: 0, y: 0, width: 0, height: 100)).isEmpty)
        #expect(TreemapLayout.squarify([100.0], in: CGRect(x: 0, y: 0, width: 100, height: 0)).isEmpty)
    }

    @Test func singleItemFillsBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 150)
        #expect(TreemapLayout.squarify([100.0], in: bounds) == [bounds])
    }

    @Test func preservesTotalAreaAndProportions() {
        let rects = TreemapLayout.squarify([60.0, 30, 10], in: square)
        #expect(rects.count == 3)
        #expect(abs(rects.map(area).reduce(0, +) - 10_000) < 1)
        let two = TreemapLayout.squarify([75.0, 25], in: square)
        #expect(abs(area(two[0]) / area(two[1]) - 3) < 0.1)
    }

    @Test func returnsAllItemsWithinBounds() {
        let bounds = CGRect(x: 10, y: 10, width: 400, height: 300)
        let rects = TreemapLayout.squarify((0..<10).map { Double(10 - $0) }, in: bounds)
        #expect(rects.count == 10)
        for r in rects {
            #expect(r.minX >= bounds.minX - 0.01 && r.maxX <= bounds.maxX + 0.01)
            #expect(r.minY >= bounds.minY - 0.01 && r.maxY <= bounds.maxY + 0.01)
        }
    }

    @Test func nonSquareBounds() {
        let rects = TreemapLayout.squarify([50.0, 50], in: CGRect(x: 0, y: 0, width: 400, height: 100))
        #expect(rects.count == 2)
        #expect(abs(rects.map(area).reduce(0, +) - 40_000) < 1)
    }

    @Test func zeroSizesAreLeftOut() {
        #expect(TreemapLayout.squarify([5.0, 3, 0, 0], in: square).count == 2)
    }

    @Test func worstRatioEdgeCases() {
        #expect(TreemapLayout.worstRatio(maxArea: 100, minArea: 100, rowSum: 100, side: 10) >= 1)
        #expect(TreemapLayout.worstRatio(maxArea: 100, minArea: 100, rowSum: 0, side: 10) == .greatestFiniteMagnitude)
        #expect(TreemapLayout.worstRatio(maxArea: 100, minArea: 100, rowSum: 100, side: 0) == .greatestFiniteMagnitude)
    }

    @Test func hundredThousandItemsAreAllLaidOutWithoutEarlyExit() {
        let sizes = (0..<100_000).map { 1e9 / pow(Double($0 + 1), 1.1) }
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let rects = TreemapLayout.squarify(sizes, in: bounds)
        #expect(rects.count == sizes.count)
        #expect(abs(rects.map(area).reduce(0, +) - 1_600_000) < 1)
    }

    @Test func earlyExitStopsAtThinRows() {
        let sizes = (0..<100_000).map { 1e9 / pow(Double($0 + 1), 1.1) }
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let rects = TreemapLayout.squarify(sizes, in: bounds, minThickness: 1)
        #expect(rects.count < sizes.count)
        #expect(rects.count > 100)
        // What is drawn still covers nearly the whole area, and nothing is
        // thinner than a point in both directions.
        #expect(rects.map(area).reduce(0, +) > 1_600_000 * 0.9)
        #expect(rects.allSatisfy { $0.width >= 1 || $0.height >= 1 })
    }
}

@Suite struct TreemapLayoutTests {
    private func file(_ name: String, _ size: UInt64) -> FileNode {
        FileNode(name: name, size: size, isDirectory: false)
    }

    /// root: big/ (a 600, b 200), c 150, small/ (d 50)
    private func sampleTree() -> FileNode {
        FileNode(name: "/root", isDirectory: true, children: [
            FileNode(name: "big", isDirectory: true, children: [file("a", 600), file("b", 200)]),
            file("c", 150),
            FileNode(name: "small", isDirectory: true, children: [file("d", 50)]),
        ])
    }

    @Test func nestsDirectoriesParentsFirst() {
        let root = sampleTree()
        let layout = TreemapLayout(focus: root, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let names = layout.tiles.map(\.node.name)
        #expect(names.first == "big")
        let big = layout.tiles[0]
        #expect(big.showsChildren)
        #expect(big.depth == 0)
        // Children of big come right after it, inside its frame below the header.
        #expect(Array(names[1...2]) == ["a", "b"])
        for i in 1...2 {
            let t = layout.tiles[i]
            #expect(t.depth == 1)
            #expect(t.parent == 0)
            #expect(t.rect.minY >= big.rect.minY + layout.options.headerHeight - 0.001)
            #expect(big.rect.contains(t.rect))
        }
        #expect(big.subtreeEnd == 3)
        #expect(Set(names) == ["big", "a", "b", "c", "small", "d"])
        withExtendedLifetime(root) {}
    }

    @Test func maxDepthLimitsNesting() {
        let root = sampleTree()
        var options = TreemapLayout.Options()
        options.maxDepth = 1
        let layout = TreemapLayout(focus: root, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), options: options)
        #expect(layout.tiles.map(\.node.name) == ["big", "c", "small"])
        #expect(layout.tiles.allSatisfy { !$0.showsChildren })
        withExtendedLifetime(root) {}
    }

    @Test func smallDirectoriesDoNotNest() {
        let root = sampleTree()
        let layout = TreemapLayout(focus: root, bounds: CGRect(x: 0, y: 0, width: 60, height: 50))
        #expect(layout.tiles.filter(\.showsChildren).allSatisfy {
            $0.rect.width >= layout.options.minNestedWidth && $0.rect.height >= layout.options.minNestedHeight
        })
        #expect(!layout.tiles.contains { $0.node.name == "d" })
        withExtendedLifetime(root) {}
    }

    @Test func hitTestFindsTheDeepestTile() {
        let root = sampleTree()
        let layout = TreemapLayout(focus: root, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        for (index, tile) in layout.tiles.enumerated() where !tile.showsChildren {
            let center = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
            #expect(layout.hitTest(center) == index, "\(tile.node.name)")
        }
        // The header strip of a nested folder hits the folder itself.
        let big = layout.tiles[0].rect
        #expect(layout.hitTest(CGPoint(x: big.midX, y: big.minY + 2)) == 0)
        #expect(layout.hitTest(CGPoint(x: -5, y: 10)) == nil)
        #expect(layout.hitTest(CGPoint(x: 800, y: 10)) == nil)
        withExtendedLifetime(root) {}
    }

    @Test func arrowKeysMoveSpatially() {
        // Four equal files in a 2x2 grid.
        let root = FileNode(name: "/r", isDirectory: true, children: (0..<4).map { file("f\($0)", 100) })
        let layout = TreemapLayout(focus: root, bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(layout.tiles.count == 4)
        func at(_ x: CGFloat, _ y: CGFloat) -> Int { layout.hitTest(CGPoint(x: x, y: y))! }
        let topLeft = at(50, 50), topRight = at(150, 50), bottomLeft = at(50, 150), bottomRight = at(150, 150)
        #expect(Set([topLeft, topRight, bottomLeft, bottomRight]).count == 4)
        #expect(layout.move(from: topLeft, direction: .right) == topRight)
        #expect(layout.move(from: topLeft, direction: .down) == bottomLeft)
        #expect(layout.move(from: bottomRight, direction: .up) == topRight)
        #expect(layout.move(from: bottomRight, direction: .left) == bottomLeft)
        #expect(layout.move(from: topLeft, direction: .left) == nil)
        #expect(layout.move(from: topLeft, direction: .up) == nil)
        withExtendedLifetime(root) {}
    }

    @Test func arrowKeysCrossFolderFramesAtTheSameDepth() {
        // Two folders side by side, each with one file: moving right from the
        // file in the left folder skips the right folder's header and frame
        // and lands on its file.
        let root = FileNode(name: "/r", isDirectory: true, children: [
            FileNode(name: "L", isDirectory: true, children: [file("l", 100)]),
            FileNode(name: "R", isDirectory: true, children: [file("r", 100)]),
        ])
        let layout = TreemapLayout(focus: root, bounds: CGRect(x: 0, y: 0, width: 400, height: 200))
        let l = layout.tiles.firstIndex { $0.node.name == "l" }!
        let r = layout.tiles.firstIndex { $0.node.name == "r" }!
        #expect(layout.move(from: l, direction: .right) == r)
        #expect(layout.move(from: r, direction: .left) == l)
        // From a folder tile, moving stays at folder depth.
        let leftFolder = layout.tiles.firstIndex { $0.node.name == "L" }!
        let rightFolder = layout.tiles.firstIndex { $0.node.name == "R" }!
        #expect(layout.move(from: leftFolder, direction: .right) == rightFolder)
        #expect(layout.parent(of: l) == leftFolder)
        #expect(layout.firstChild(of: leftFolder) == l)
        #expect(layout.firstChild(of: l) == nil)
        withExtendedLifetime(root) {}
    }

    @Test func layoutOfAHundredThousandFilesStaysSmall() {
        let children = (0..<100_000).map { file("f\($0)", UInt64(1e9 / pow(Double($0 + 1), 1.1)) + 1) }
        let root = FileNode(name: "/big", isDirectory: true, children: children)
        let layout = TreemapLayout(focus: root, bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        #expect(layout.tiles.count < 100_000)
        #expect(layout.tiles.count > 100)
        withExtendedLifetime(root) {}
    }
}
