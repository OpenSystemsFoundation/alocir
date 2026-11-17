import AlocirCore
import Darwin

// Scans a folder the way the app does and prints the total, the largest
// top-level entries and the time taken, in the same format as the Rust
// `scan_total` example, so CI can compare the two:
//
//     alocir-scan PATH
//     alocir-scan --fallback PATH   (readdir + fstatat instead of getattrlistbulk)

var arguments = Array(CommandLine.arguments.dropFirst())
var fallback = false
if let index = arguments.firstIndex(of: "--fallback") {
    fallback = true
    arguments.remove(at: index)
}
guard arguments.count == 1 else {
    print("usage: alocir-scan [--fallback] PATH")
    exit(2)
}
let path = arguments[0]

var scanner = Scanner()
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
withExtendedLifetime(node) {}
