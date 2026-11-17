import Testing
@testable import AlocirCore

@Suite struct SearchQueryTests {
    private func file(_ name: String, _ size: UInt64 = 100) -> FileNode {
        FileNode(name: name, size: size, isDirectory: false)
    }

    @Test func parsesTokens() {
        #expect(SearchQuery("") == nil)
        #expect(SearchQuery("   ") == nil)
        #expect(SearchQuery("report .mp4 *.MOV >500mb <1.5gb")!.terms == [
            .name("report"), .fileExtension("mp4"), .fileExtension("MOV"),
            .larger(500 * 1_048_576), .smaller(1_610_612_736),
        ])
        #expect(SearchQuery(">10k")!.terms == [.larger(10_240)])
        #expect(SearchQuery(">200")!.terms == [.larger(200)])
        // Not a size: falls back to a name.
        #expect(SearchQuery(">abc")!.terms == [.name(">abc")])
        #expect(SearchQuery(".")!.terms == [.name(".")])
    }

    @Test func namesMatchIgnoringCase() {
        let q = SearchQuery("RePort")!
        #expect(q.matches(file("Annual report.pdf")))
        #expect(q.matches(file("REPORT")))
        #expect(!q.matches(file("repo")))
    }

    @Test func nonASCIIUsesCaseAndDiacriticInsensitiveCompare() {
        let q = SearchQuery("café")!
        #expect(q.matches(file("Le CAFE.txt")))
        #expect(q.matches(file("le café.txt")))
        #expect(SearchQuery("Ü")!.matches(file("über.txt")))
    }

    @Test func extensions() {
        let q = SearchQuery("*.mp4")!
        #expect(q.matches(file("movie.MP4")))
        #expect(!q.matches(file("movie.mp4.part")))
        #expect(!q.matches(file("mp4")))
        #expect(!q.matches(file(".mp4")))
        #expect(SearchQuery(".app")!.matches(FileNode(name: "Tool.app", isDirectory: true)))
    }

    @Test func sizesOnlyMatchFiles() {
        let q = SearchQuery(">1kb")!
        #expect(q.matches(file("a", 2048)))
        #expect(!q.matches(file("a", 1024)))
        let dir = FileNode(name: "d", isDirectory: true, children: [file("x", 4096)])
        #expect(!q.matches(dir))
        #expect(SearchQuery("<1kb")!.matches(file("a", 10)))
    }

    @Test func allTermsMustMatch() {
        let q = SearchQuery("holiday .jpg >1mb")!
        #expect(q.matches(file("Holiday 2026.JPG", 5_000_000)))
        #expect(!q.matches(file("Holiday 2026.JPG", 50)))
        #expect(!q.matches(file("Holiday 2026.png", 5_000_000)))
        #expect(!q.matches(file("Work.jpg", 5_000_000)))
    }
}

@MainActor
@Suite struct TreeSearchTests {
    private func file(_ name: String, _ size: UInt64) -> FileNode {
        FileNode(name: name, size: size, isDirectory: false)
    }

    private func sample() -> LiveTree {
        let root = FileNode(name: "/r", isDirectory: true, children: [
            FileNode(name: "Photos", isDirectory: true, children: [
                file("beach.jpg", 3000), file("notes.txt", 10),
                FileNode(name: "jpg-archive", isDirectory: true, children: [file("old.jpg", 500)]),
            ]),
            file("cover.JPG", 200),
            file("readme.md", 5),
        ])
        return LiveTree(root: root, scanPath: "/r")
    }

    @Test func findsMatchesMarksThemAndTheirAncestors() async {
        let tree = sample()
        let search = TreeSearch(debounce: .zero)
        search.setText(".jpg", in: tree)
        await search.waitUntilDone()
        let result = search.result!
        #expect(Set(result.matches.map(\.name)) == ["beach.jpg", "old.jpg", "cover.JPG"])
        #expect(result.totalSize == 3700)
        let photos = tree.root.child("Photos")!
        #expect(photos.searchMark == SearchMark.containsMatch)
        #expect(photos.child("beach.jpg")!.searchMark == SearchMark.match)
        #expect(photos.child("notes.txt")!.searchMark == 0)
        #expect(tree.root.searchMark & SearchMark.containsMatch != 0)
        #expect(!search.isSearching)

        // A new query clears the old marks first.
        search.setText("notes", in: tree)
        await search.waitUntilDone()
        #expect(search.result!.count == 1)
        #expect(photos.child("beach.jpg")!.searchMark == 0)
        #expect(photos.child("notes.txt")!.searchMark == SearchMark.match)

        // Clearing the query clears every mark.
        search.setText("", in: tree)
        #expect(search.result == nil)
        #expect(photos.child("notes.txt")!.searchMark == 0)
        #expect(tree.root.searchMark == 0)
    }

    @Test func aMatchInsideAMatchIsCountedOnce() async {
        let tree = sample()
        let search = TreeSearch(debounce: .zero)
        search.setText("jpg", in: tree)
        await search.waitUntilDone()
        let result = search.result!
        #expect(Set(result.matches.map(\.name)) == ["beach.jpg", "jpg-archive", "old.jpg", "cover.JPG"])
        // old.jpg is inside jpg-archive, which already counts it.
        #expect(result.totalSize == 3000 + 500 + 200)
    }

    @Test func slicedSearchOverManyNodesFinishes() async {
        let dirs = (0..<200).map { d in
            FileNode(name: "d\(d)", isDirectory: true, children: (0..<500).map { f in
                FileNode(name: "file\(f).\(f % 2 == 0 ? "mov" : "txt")", size: UInt64(f + 1), isDirectory: false)
            })
        }
        let tree = LiveTree(root: FileNode(name: "/many", isDirectory: true, children: dirs), scanPath: "/many")
        let search = TreeSearch(debounce: .zero, sliceMilliseconds: 1)
        search.setText(".mov", in: tree)
        await search.waitUntilDone()
        #expect(search.result?.count == 200 * 250)
    }
}
