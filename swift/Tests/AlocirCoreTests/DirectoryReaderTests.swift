import Darwin
import Testing
@testable import AlocirCore

@Suite struct DirectoryReaderTests {
    private func entries(_ path: String, fallback: Bool) -> [String: DirectoryEntry] {
        var result: [String: DirectoryEntry] = [:]
        guard let reader = DirectoryReader(path: path) else {
            Issue.record("cannot open \(path)")
            return [:]
        }
        reader.forEachEntry(forceFallback: fallback) { result[$0.name] = $0 }
        return result
    }

    @Test func bulkAllocatedSizeMatchesLstatBlocks() {
        let tree = TempTree()
        tree.file("small.txt", bytes: 10)
        tree.file("big.bin", bytes: 300_000, fill: 7)
        tree.sparse("sparse.img", length: 100 * 1024 * 1024)
        tree.dir("linked")
        tree.file("linked/data.bin", bytes: 64 * 1024, fill: 1)
        tree.hardLink("linked/data.bin", "same.bin")

        let bulk = entries(tree.root, fallback: false)
        for name in ["small.txt", "big.bin", "sparse.img", "same.bin"] {
            let entry = bulk[name]!
            let st = lstatInfo(tree.path(name))!
            #expect(entry.type == .regular, "\(name)")
            #expect(entry.allocatedSize == diskUsage(st), "\(name)")
            #expect(entry.linkCount == UInt32(st.st_nlink), "\(name)")
            #expect(entry.id == fileID(st), "\(name)")
        }
        #expect(bulk["sparse.img"]!.allocatedSize < 1024 * 1024)
        #expect(bulk["same.bin"]!.linkCount == 2)
        #expect(bulk["linked"]!.type == .directory)
    }

    @Test func fallbackListsTheSameAsBulk() {
        let tree = TempTree()
        tree.file("a.txt", bytes: 5000)
        tree.file("Ünïcödé 📁.txt", bytes: 12)
        tree.dir("sub")
        tree.symlink("a.txt", "link")
        let bulk = entries(tree.root, fallback: false)
        let fallback = entries(tree.root, fallback: true)
        #expect(Set(bulk.keys) == ["a.txt", "Ünïcödé 📁.txt", "sub", "link"])
        #expect(Set(bulk.keys) == Set(fallback.keys))
        for (name, entry) in bulk {
            #expect(entry.type == fallback[name]!.type, "\(name)")
            if entry.type == .regular {
                #expect(entry.allocatedSize == fallback[name]!.allocatedSize, "\(name)")
            }
        }
        #expect(bulk["link"]!.type == .symlink)
    }

    @Test func manyEntriesSpanSeveralBulkCalls() {
        let tree = TempTree()
        // Long names make each record large, so 64 KB holds a few hundred.
        let prefix = String(repeating: "x", count: 120)
        for i in 0..<3000 { tree.file("\(prefix)-\(i)", bytes: 1) }
        let bulk = entries(tree.root, fallback: false)
        #expect(bulk.count == 3000)
    }

    @Test func directoryIdComesFromTheOpenDescriptor() {
        let tree = TempTree()
        guard let reader = DirectoryReader(path: tree.root) else {
            Issue.record("cannot open")
            return
        }
        #expect(reader.id == fileID(lstatInfo(tree.root)!))
    }

    @Test func openRefusesSymlinksAndFiles() {
        let tree = TempTree()
        tree.dir("real")
        tree.symlink("real", "link")
        tree.file("file", bytes: 1)
        #expect(!canOpenDirectory(tree.path("link")))
        #expect(!canOpenDirectory(tree.path("file")))
        #expect(canOpenDirectory(tree.path("real")))
    }
}
