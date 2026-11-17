import Testing
@testable import AlocirCore

@Suite struct DiskScannerTests {
    @Test(arguments: [false, true])
    func sumsNestedSizesAndSkipsSymlinks(fallback: Bool) {
        let tree = TempTree()
        tree.dir("a/b")
        tree.file("top.txt", bytes: 10)
        tree.file("a/one.bin", bytes: 100)
        tree.file("a/b/two.bin", bytes: 1000)
        tree.dir("empty")
        tree.symlink("a", "link")
        let (top, one, two) = (tree.usage("top.txt"), tree.usage("a/one.bin"), tree.usage("a/b/two.bin"))

        var scanner = DiskScanner()
        scanner.useFallbackReader = fallback
        let progress = ScanProgress()
        let node = scanner.scanSynchronously(path: tree.root, progress: progress)

        #expect(node.isDirectory)
        #expect(node.name == tree.root)
        #expect(node.size == top + one + two)
        // The symlink is skipped; "empty" is last (size 0).
        #expect(node.children.last?.name == "empty")
        #expect(Set(node.children.map(\.name)) == ["a", "top.txt", "empty"])
        let a = node.child("a")!
        #expect(a.size == one + two)
        #expect(a.child("b")?.isDirectory == true)
        #expect(a.child("one.bin")?.kind == .other)
        #expect(node.child("top.txt")?.kind == .document)
        // root, a, b, empty (directories) + 3 files
        #expect(progress.itemsScanned == 7)
        #expect(progress.bytesScanned == top + one + two)
        #expect(node.child("a")!.child("b")!.child("two.bin")!.path == tree.path("a/b/two.bin"))
    }

    @Test func countsDiskUsageAndHardLinksOnce() {
        let tree = TempTree()
        tree.dir("x")
        tree.dir("y")
        tree.file("x/data.bin", bytes: 64 * 1024, fill: 1)
        tree.hardLink("x/data.bin", "y/same.bin")
        tree.sparse("sparse.img", length: 100 * 1024 * 1024)
        let data = tree.usage("x/data.bin")

        let node = DiskScanner().scanSynchronously(path: tree.root)
        let sparse = node.child("sparse.img")!.size

        #expect(data >= 64 * 1024)
        #expect(sparse < 1024 * 1024, "sparse file counted as \(sparse) bytes")
        // The hard-linked file counts once, in whichever folder was seen first.
        #expect(node.size == data + sparse)
    }

    @Test func skipsExcludedDirectories() {
        let tree = TempTree()
        tree.dir("skip")
        tree.file("skip/big.bin", bytes: 50_000)
        tree.file("keep.bin", bytes: 5)
        let keep = tree.usage("keep.bin")

        let node = DiskScanner(excluded: [tree.path("skip")]).scanSynchronously(path: tree.root)
        #expect(node.size == keep)
        #expect(node.child("skip")?.children.isEmpty == true)
    }

    @Test func directoryReachedTwiceIsCountedOnce() {
        // A second path to an already-visited directory (a firmlink or bind
        // mount in real life) is skipped because it has the same
        // (device, inode). Simulate it by scanning a subdirectory again with
        // the same state.
        let tree = TempTree()
        tree.dir("data/users")
        tree.file("data/users/f.bin", bytes: 8192, fill: 1)
        let state = ScanState()
        let progress = ScanProgress()
        let scanner = DiskScanner()
        let first = scanner.scanEntryForTesting(path: tree.root, state: state, progress: progress)
        let again = scanner.scanEntryForTesting(
            path: tree.path("data/users"), state: state, progress: progress)
        #expect(first!.size > 0)
        #expect(again == nil, "an already-visited directory must be skipped")
    }

    @Test func deferredVolumeIsScannedLastAndGrafted() {
        let tree = TempTree()
        tree.dir("System/Volumes/Data/.Spotlight-V100")
        tree.file("System/Volumes/Data/.Spotlight-V100/index", bytes: 50_000, fill: 2)
        tree.file("System/kernel", bytes: 10, fill: 3)
        var scanner = DiskScanner()
        scanner.deferredVolume = tree.path("System/Volumes/Data")
        let node = scanner.scanSynchronously(path: tree.root)

        let system = node.child("System")!
        let volumes = system.child("Volumes")!
        let data = volumes.child("Data")!
        #expect(data.child(".Spotlight-V100") != nil)
        #expect(node.size == tree.usage("System/kernel") + tree.usage("System/Volumes/Data/.Spotlight-V100/index"))
        #expect(system.size == node.size)
        #expect(system.children.first?.name == "Volumes")
        #expect(data.parent === volumes)
    }

    @Test func deferredVolumeIsScannedNormallyWhenItIsTheRoot() {
        let tree = TempTree()
        tree.file("f", bytes: 100)
        var scanner = DiskScanner()
        scanner.deferredVolume = tree.root
        let node = scanner.scanSynchronously(path: tree.root)
        #expect(node.size == tree.usage("f"))
    }

    @Test func graftInsertsNodeAndUpdatesAncestorSizes() {
        let root = FileNode(name: "/", isDirectory: true, children: [
            FileNode(name: "System", isDirectory: true, children: [
                FileNode(name: "kernel", size: 10, isDirectory: false),
            ]),
        ])
        let data = FileNode(name: "Data", isDirectory: true, children: [
            FileNode(name: ".Spotlight-V100", size: 50, isDirectory: false),
        ])
        root.graft(["System", "Volumes", "Data"], data)

        #expect(root.size == 60)
        let system = root.children[0]
        #expect(system.size == 60)
        // "Volumes" was created and sorted ahead of the smaller "kernel".
        #expect(system.children[0].name == "Volumes")
        #expect(system.children[0].size == 50)
        #expect(system.children[0].children[0].name == "Data")
        #expect(data.path == "/System/Volumes/Data")
    }

    @Test func rootThatIsAFileOrSymlink() {
        let tree = TempTree()
        tree.file("f.bin", bytes: 5000)
        tree.symlink("f.bin", "link")
        let file = DiskScanner().scanSynchronously(path: tree.path("f.bin"))
        #expect(!file.isDirectory)
        #expect(file.size == tree.usage("f.bin"))
        let link = DiskScanner().scanSynchronously(path: tree.path("link"))
        #expect(!link.isDirectory)
        #expect(link.size == 0)
    }

    @Test func missingRootIsAnEmptyFile() {
        let node = DiskScanner().scanSynchronously(path: "/nonexistent-alocir-\(UInt64.random(in: 0...UInt64.max))")
        #expect(node.size == 0)
        #expect(node.children.isEmpty)
    }

    @Test func childrenAreSortedLargestFirstAtEveryLevel() {
        let tree = TempTree()
        tree.dir("d")
        for (i, size) in [3000, 100_000, 50, 20_000].enumerated() {
            tree.file("f\(i)", bytes: size, fill: 1)
            tree.file("d/g\(i)", bytes: size, fill: 1)
        }
        let node = DiskScanner().scanSynchronously(path: tree.root)
        func check(_ n: FileNode) {
            let sizes = n.children.map(\.size)
            #expect(sizes == sizes.sorted(by: >))
            #expect(n.children.allSatisfy { $0.parent === n })
            n.children.forEach(check)
        }
        check(node)
    }

    @Test func manyDirectoriesInParallelGiveTheSameTotalAsFallback() {
        let tree = TempTree()
        for i in 0..<40 {
            for j in 0..<10 {
                tree.dir("d\(i)/e\(j)")
                tree.file("d\(i)/e\(j)/f", bytes: (i + 1) * (j + 1) * 100, fill: 1)
            }
        }
        let bulkProgress = ScanProgress()
        let bulk = DiskScanner().scanSynchronously(path: tree.root, progress: bulkProgress)
        var fallbackScanner = DiskScanner()
        fallbackScanner.useFallbackReader = true
        let fallbackProgress = ScanProgress()
        let fallback = fallbackScanner.scanSynchronously(path: tree.root, progress: fallbackProgress)
        #expect(bulk.size == fallback.size)
        #expect(bulk.nodeCount == fallback.nodeCount)
        #expect(bulkProgress.itemsScanned == fallbackProgress.itemsScanned)
        #expect(bulk.nodeCount == 1 + 40 + 400 + 400)
    }

    @Test func asyncScanCanBeCancelled() async throws {
        let tree = TempTree()
        for i in 0..<200 { tree.dir("d\(i)/e") }
        let progress = ScanProgress()
        progress.cancel()
        await #expect(throws: CancellationError.self) {
            try await DiskScanner().scan(path: tree.root, progress: progress)
        }
    }

    @Test func asyncScanReturnsTheTree() async throws {
        let tree = TempTree()
        tree.file("a", bytes: 4096, fill: 1)
        let node = try await DiskScanner().scan(path: tree.root)
        #expect(node.size == tree.usage("a"))
    }

    @Test func pathHelpers() {
        #expect(DiskScanner.normalize("/Users/me/") == "/Users/me")
        #expect(DiskScanner.normalize("/") == "/")
        #expect(DiskScanner.join("/", "Users") == "/Users")
        #expect(DiskScanner.join("/Users", "me") == "/Users/me")
        #expect(DiskScanner.components(of: "/System/Volumes/Data", below: "/") == ["System", "Volumes", "Data"])
        #expect(DiskScanner.components(of: "/a/b/c", below: "/a") == ["b", "c"])
        #expect(DiskScanner.components(of: "/ab/c", below: "/a") == [])
    }
}
