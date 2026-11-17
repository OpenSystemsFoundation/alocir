import CoreServices
import Darwin
import Foundation
import Testing
@testable import AlocirCore

@MainActor
@Suite struct LiveTreeTests {
    private func liveTree(_ tree: TempTree, scanner: Scanner = Scanner()) -> LiveTree {
        let root = scanner.scanSynchronously(path: tree.root)
        return LiveTree(root: root, scanPath: tree.root, scanner: scanner)
    }

    private func names(_ node: FileNode) -> [String] {
        node.children.map(\.name).sorted()
    }

    private func node(_ live: LiveTree, _ names: String...) -> FileNode {
        live.directory(at: names)!
    }

    /// Writes `bytes` bytes to an existing or new file.
    private func write(_ tree: TempTree, _ relative: String, bytes: Int) {
        tree.file(relative, bytes: bytes, fill: 1)
    }

    @Test func tracksCreateRenameRemoveAndNewDirectories() async {
        let tree = TempTree()
        tree.dir("sub")
        write(tree, "sub/a.bin", bytes: 100_000)
        let live = liveTree(tree)
        live.focus = node(live, "sub")
        let a = tree.usage("sub/a.bin")
        let versionBefore = live.version

        // New file
        write(tree, "sub/b.bin", bytes: 50_000)
        let b = tree.usage("sub/b.bin")
        live.reconcile(tree.path("sub/b.bin"))
        #expect(names(live.focus) == ["a.bin", "b.bin"])
        #expect(live.root.size == a + b)
        #expect(live.version > versionBefore)

        // Rename: both paths reported, in either order
        rename(tree.path("sub/b.bin"), tree.path("sub/c.bin"))
        live.reconcile(tree.path("sub/c.bin"))
        live.reconcile(tree.path("sub/b.bin"))
        #expect(names(live.focus) == ["a.bin", "c.bin"])
        #expect(live.root.size == a + b)

        // Grown file
        write(tree, "sub/c.bin", bytes: 500_000)
        let c = tree.usage("sub/c.bin")
        live.reconcile(tree.path("sub/c.bin"))
        #expect(live.root.size == a + c)
        #expect(live.focus.children[0].name == "c.bin")

        // Removed file
        unlink(tree.path("sub/a.bin"))
        live.reconcile(tree.path("sub/a.bin"))
        #expect(names(live.focus) == ["c.bin"])
        #expect(live.root.size == c)

        // A directory with nested contents appears: placeholder, then full size
        tree.dir("sub/new/deep")
        write(tree, "sub/new/deep/x.bin", bytes: 1_000_000)
        let x = tree.usage("sub/new/deep/x.bin")
        live.reconcile(tree.path("sub/new"))
        #expect(names(live.focus) == ["c.bin", "new"])
        await live.waitForBackgroundScans()
        #expect(live.root.size == c + x)
        #expect(live.focus.size == c + x)
        #expect(node(live, "sub", "new", "deep").size == x)

        // Events for unchanged or missing paths elsewhere, or outside the
        // scan root, change nothing.
        live.reconcile(tree.path("sub"))
        live.reconcile(tree.path("elsewhere.bin"))
        live.reconcile(tree.path("missing/deeper/x.bin"))
        live.reconcile("/tmp/not-ours-\(UUID().uuidString).bin")
        live.reconcile(tree.root)
        await live.waitForBackgroundScans()
        #expect(names(live.focus) == ["c.bin", "new"])
        #expect(live.root.size == c + x)
    }

    @Test func twoLevelsBelowFocusUpdatesAllAncestors() async {
        let tree = TempTree()
        tree.dir("a/b")
        write(tree, "top.bin", bytes: 10_000)
        write(tree, "a/b/f.bin", bytes: 20_000)
        let live = liveTree(tree)
        let top = tree.usage("top.bin")
        let f = tree.usage("a/b/f.bin")
        #expect(live.focus === live.root)

        write(tree, "a/b/g.bin", bytes: 300_000)
        let g = tree.usage("a/b/g.bin")
        live.reconcile(tree.path("a/b/g.bin"))
        #expect(node(live, "a", "b").size == f + g)
        #expect(node(live, "a").size == f + g)
        #expect(live.root.size == top + f + g)
        // The root's children were re-sorted: "a" is now the largest.
        #expect(live.root.children[0].name == "a")

        unlink(tree.path("a/b/f.bin"))
        live.reconcile(tree.path("a/b/f.bin"))
        #expect(node(live, "a", "b").size == g)
        #expect(live.root.size == top + g)

        // A file inside a directory the tree doesn't know: the highest
        // missing directory is reconciled (and scanned) instead.
        tree.dir("a/n1/n2")
        write(tree, "a/n1/n2/h.bin", bytes: 40_000)
        let h = tree.usage("a/n1/n2/h.bin")
        live.reconcile(tree.path("a/n1/n2/h.bin"))
        await live.waitForBackgroundScans()
        #expect(live.root.size == top + g + h)
        #expect(node(live, "a", "n1", "n2").size == h)
        #expect(node(live, "a").size == g + h)
    }

    @Test func focusStaysOnTheSameDirectoryAndFallsBackWhenDeleted() {
        let tree = TempTree()
        tree.dir("big")
        tree.dir("small/inner")
        write(tree, "big/x.bin", bytes: 500_000)
        write(tree, "small/inner/y.bin", bytes: 10_000)
        let live = liveTree(tree)
        let inner = node(live, "small", "inner")
        live.focus = inner
        #expect(live.root.children[1].name == "small")

        // small/inner grows past big, so "small" moves to index 0.
        write(tree, "small/inner/z.bin", bytes: 2_000_000)
        live.reconcile(tree.path("small/inner/z.bin"))
        #expect(live.root.children[0].name == "small")
        #expect(live.focus === inner)
        #expect(live.focus.path == tree.path("small/inner"))
        #expect(names(live.focus) == ["y.bin", "z.bin"])

        // A change under a sibling moves it back.
        write(tree, "big/w.bin", bytes: 4_000_000)
        live.reconcile(tree.path("big/w.bin"))
        #expect(live.root.children[0].name == "big")
        #expect(live.focus === inner)

        // Deleting the focused folder falls back to its nearest surviving
        // ancestor, and clears a selection inside it.
        live.selection = inner.children[0]
        try? FileManager.default.removeItem(atPath: tree.path("small/inner"))
        live.reconcile(tree.path("small/inner"))
        #expect(live.focus.path == tree.path("small"))
        #expect(live.selection == nil)
        #expect(live.isAttached(live.focus))
    }

    @Test func deletingAnAncestorOfTheFocusFallsBackAboveIt() {
        let tree = TempTree()
        tree.dir("a/b/c")
        write(tree, "a/b/c/f", bytes: 1000)
        let live = liveTree(tree)
        live.focus = node(live, "a", "b", "c")
        try? FileManager.default.removeItem(atPath: tree.path("a"))
        live.reconcile(tree.path("a"))
        #expect(live.focus === live.root)
        #expect(live.root.size == 0)
    }

    @Test func rescanBatchRescansTheAffectedDirectory() async {
        let tree = TempTree()
        tree.dir("d/e")
        write(tree, "d/e/a.bin", bytes: 10_000)
        let live = liveTree(tree)
        let a = tree.usage("d/e/a.bin")

        // Changes the watcher never reported individually.
        write(tree, "d/e/b.bin", bytes: 70_000)
        tree.dir("d/e/new")
        write(tree, "d/e/new/c.bin", bytes: 30_000)
        unlink(tree.path("d/e/a.bin"))
        let (b, c) = (tree.usage("d/e/b.bin"), tree.usage("d/e/new/c.bin"))
        #expect(live.root.size == a)

        live.apply(FSEventsWatcher.Batch(rescans: [tree.path("d/e")]))
        #expect(live.scansInFlight == [tree.path("d/e")])
        await live.waitForBackgroundScans()
        #expect(live.root.size == b + c)
        #expect(node(live, "d", "e", "new").size == c)
        #expect(node(live, "d").size == b + c)
        #expect(live.scansInFlight.isEmpty)

        // A rescan of a path outside the root rescans the whole tree.
        write(tree, "top.bin", bytes: 5_000)
        let top = tree.usage("top.bin")
        live.apply(FSEventsWatcher.Batch(rescans: ["/"]))
        #expect(live.scansInFlight == [tree.root])
        await live.waitForBackgroundScans()
        #expect(live.root.size == b + c + top)
        #expect(live.root.name == tree.root)
    }

    @Test func rescanOfAnUnknownDirectoryRescansTheDeepestKnownOne() async {
        let tree = TempTree()
        tree.dir("k")
        let live = liveTree(tree)
        tree.dir("k/u1/u2")
        write(tree, "k/u1/u2/f", bytes: 9000)
        live.rescan(tree.path("k/u1/u2"))
        #expect(live.scansInFlight == [tree.path("k")])
        await live.waitForBackgroundScans()
        #expect(live.root.size == tree.usage("k/u1/u2/f"))
    }

    @Test func duplicatePathsInABatchAreReconciledOnce() async {
        let tree = TempTree()
        tree.dir("s")
        let live = liveTree(tree)
        tree.dir("s/newdir")
        write(tree, "s/newdir/f.bin", bytes: 10_000)
        let f = tree.usage("s/newdir/f.bin")

        let raw = Array(repeating: tree.path("s/newdir"), count: 1000)
        let batch = FSEventsWatcher.makeBatch(paths: raw, flags: Array(repeating: 0, count: 1000))
        #expect(batch.paths == [tree.path("s/newdir")])
        live.apply(batch)
        // One placeholder and one background scan, not a thousand.
        #expect(live.scansInFlight == [tree.path("s/newdir")])
        await live.waitForBackgroundScans()
        #expect(live.root.size == f)
    }

    @Test func aScanOfAnAncestorSupersedesScansBelowIt() async {
        let tree = TempTree()
        tree.dir("p/q")
        let live = liveTree(tree)
        write(tree, "p/q/f", bytes: 3000)
        live.scanInBackground(tree.path("p/q"))
        live.scanInBackground(tree.path("p"))
        #expect(live.scansInFlight == [tree.path("p")])
        // A scan below a running one only marks it to run again.
        live.scanInBackground(tree.path("p/q"))
        #expect(live.scansInFlight == [tree.path("p")])
        await live.waitForBackgroundScans()
        #expect(live.root.size == tree.usage("p/q/f"))
    }

    @Test func canonicalPathsAreMappedToTheScanPath() {
        // /tmp is a symlink to /private/tmp on macOS; FSEvents reports the
        // resolved form.
        let tree = TempTree()
        let viaSymlink = tree.root.replacingOccurrences(of: "/private/var/", with: "/var/")
        guard viaSymlink != tree.root else { return }
        let root = Scanner().scanSynchronously(path: viaSymlink)
        let live = LiveTree(root: root, scanPath: viaSymlink)
        #expect(live.canonicalPath == tree.root)
        write(tree, "f.bin", bytes: 7000)
        live.reconcile(tree.path("f.bin"))
        #expect(live.root.child("f.bin") != nil)
        #expect(live.relativeNames(tree.path("f.bin")) == ["f.bin"])
        #expect(live.relativeNames(viaSymlink + "/f.bin") == ["f.bin"])
    }

    @Test func excludedDirectoriesAreLeftAlone() {
        let tree = TempTree()
        tree.dir("skip")
        let scanner = Scanner(excluded: [tree.path("skip")])
        let live = liveTree(tree, scanner: scanner)
        write(tree, "skip/f", bytes: 5000)
        live.reconcile(tree.path("skip/f"))
        #expect(live.root.size == 0)
        #expect(live.relativeNames(tree.path("skip/f")) == nil)
    }

    @Test func removeAndRenameUpdateTheTree() {
        let tree = TempTree()
        tree.dir("d")
        write(tree, "d/a", bytes: 8000)
        write(tree, "b", bytes: 4000)
        let live = liveTree(tree)
        let d = node(live, "d")
        live.selection = d
        live.remove(d)
        #expect(live.root.size == tree.usage("b"))
        #expect(live.selection == nil)
        let b = live.root.child("b")!
        live.rename(b, to: "renamed")
        #expect(live.root.child("renamed") === b)
    }

    @Test func insertSortedKeepsOrder() {
        let parent = FileNode(name: "/", isDirectory: true, children: [
            FileNode(name: "a", size: 30, isDirectory: false),
            FileNode(name: "b", size: 20, isDirectory: false),
            FileNode(name: "c", size: 10, isDirectory: false),
        ])
        parent.insertSorted(FileNode(name: "x", size: 25, isDirectory: false))
        parent.insertSorted(FileNode(name: "y", size: 5, isDirectory: false))
        parent.insertSorted(FileNode(name: "z", size: 99, isDirectory: false))
        #expect(parent.children.map(\.name) == ["z", "a", "x", "b", "c", "y"])
    }

    @Test func batchesMapDroppedEventsToRescans() {
        let flags: [FSEventStreamEventFlags] = [
            0,
            FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
            0,
        ]
        let batch = FSEventsWatcher.makeBatch(
            paths: ["/a/x", "/a/", "/b", "/c", "/a/x"], flags: flags)
        #expect(batch.paths == ["/a/x"])
        #expect(batch.rescans == ["/a", "/b"])
    }

    /// End to end with the real FSEvents stream: changes two levels below the
    /// scan root show up without navigating there.
    @Test(.timeLimit(.minutes(1)))
    func realWatcherTracksDeepChanges() async throws {
        let tree = TempTree()
        tree.dir("l1/l2")
        let live = liveTree(tree)
        live.startWatching(latency: 0.1)
        #expect(live.isWatching)
        defer { live.stopWatching() }
        // FSEvents may deliver events from just before the stream started.
        try await Task.sleep(for: .milliseconds(300))

        func wait(_ what: String, _ done: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !done() {
                if ContinuousClock.now > deadline {
                    Issue.record("timed out waiting for \(what)")
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func has(_ name: String) -> Bool {
            live.directory(at: ["l1", "l2"])?.child(name) != nil
        }

        write(tree, "l1/l2/a.bin", bytes: 100_000)
        let a = tree.usage("l1/l2/a.bin")
        try await wait("create") { has("a.bin") && live.root.size == a }
        #expect(node(live, "l1").size == a)

        rename(tree.path("l1/l2/a.bin"), tree.path("l1/l2/b.bin"))
        try await wait("rename") { has("b.bin") && !has("a.bin") }
        #expect(live.root.size == a)

        unlink(tree.path("l1/l2/b.bin"))
        try await wait("delete") { !has("b.bin") }
        #expect(live.root.size == 0)

        tree.dir("l1/l2/newdir/inner")
        write(tree, "l1/l2/newdir/inner/c.bin", bytes: 20_000)
        let c = tree.usage("l1/l2/newdir/inner/c.bin")
        try await wait("new directory") { live.root.size == c }
    }
}
