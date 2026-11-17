import AlocirCore
import CoreGraphics
import Darwin

// Scans a folder the way the app does and prints the total, the largest
// top-level entries and the time taken, in the same format as the Rust
// `scan_total` example, so CI can compare the two:
//
//     alocir-scan PATH
//     alocir-scan --fallback PATH   (readdir + fstatat instead of getattrlistbulk)
//     alocir-scan --layout PATH     (also time the nested treemap layout at 1600x1000)

var arguments = Array(CommandLine.arguments.dropFirst())
var fallback = false
var timeLayout = false
if let index = arguments.firstIndex(of: "--fallback") {
    fallback = true
    arguments.remove(at: index)
}
if let index = arguments.firstIndex(of: "--layout") {
    timeLayout = true
    arguments.remove(at: index)
}
guard arguments.count == 1 else {
    print("usage: alocir-scan [--fallback] [--layout] PATH")
    exit(2)
}
let path = arguments[0]

var scanner = DiskScanner()
scanner.useFallbackReader = fallback
let progress = ScanProgress()
let clock = ContinuousClock()
let start = clock.now
let node = scanner.scanSynchronously(path: path, progress: progress)
let elapsed = clock.now - start

print("\(path): \(Formatting.size(node.size)) (\(node.size) bytes), \(progress.itemsScanned) items, \(Formatting.duration(elapsed))")
for child in node.children.prefix(12) {
    let size = Formatting.size(child.size)
    print("  " + String(repeating: " ", count: max(0, 10 - size.count)) + size + "  " + child.name)
}
if timeLayout {
    // Best of five, as the app would lay out the scan root on screen.
    var best = Duration.seconds(1_000)
    var tiles = 0
    for _ in 0..<5 {
        let layoutStart = clock.now
        let layout = TreemapLayout(focus: node, bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        best = min(best, clock.now - layoutStart)
        tiles = layout.tiles.count
    }
    let ms = Double(best.components.attoseconds) / 1e15 + Double(best.components.seconds) * 1000
    print("layout 1600x1000: \(tiles) tiles, \((ms * 100).rounded() / 100) ms")
}
withExtendedLifetime(node) {}
