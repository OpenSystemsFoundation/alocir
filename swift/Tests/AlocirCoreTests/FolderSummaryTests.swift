import Testing
@testable import AlocirCore

@Suite struct FolderKindsTests {
    @Test func eachFolderGetsTheKindWithTheMostBytes() {
        let videos = FileNode(name: "Movies", isDirectory: true, children: [
            FileNode(name: "a.mov", size: 900, isDirectory: false),
            FileNode(name: "poster.jpg", size: 100, isDirectory: false),
        ])
        let deep = FileNode(name: "deep", isDirectory: true, children: [
            FileNode(name: "x.zip", size: 50, isDirectory: false),
        ])
        let mixed = FileNode(name: "Mixed", isDirectory: true, children: [
            FileNode(name: "photos", isDirectory: true, children: [
                FileNode(name: "1.jpg", size: 300, isDirectory: false),
                FileNode(name: "2.jpg", size: 300, isDirectory: false),
                deep,
            ]),
            FileNode(name: "notes.txt", size: 400, isDirectory: false),
        ])
        let empty = FileNode(name: "Empty", isDirectory: true, children: [FileNode(name: "nothing", isDirectory: true)])
        let root = FileNode(name: "/r", isDirectory: true, children: [videos, mixed, empty])

        let all = FolderKinds.dominantKinds(below: root, levels: 8)
        #expect(all[ObjectIdentifier(videos)] == .video)
        // 600 bytes of images in a subfolder beat 400 of documents.
        #expect(all[ObjectIdentifier(mixed)] == .image)
        #expect(all[ObjectIdentifier(deep)] == .archive)
        #expect(all[ObjectIdentifier(root)] == .video)
        // No files anywhere below: no kind.
        #expect(all[ObjectIdentifier(empty)] == nil)

        // Only as deep as asked, but sums still include everything below.
        let shallow = FolderKinds.dominantKinds(below: root, levels: 1)
        #expect(shallow[ObjectIdentifier(mixed)] == .image)
        #expect(shallow[ObjectIdentifier(deep)] == nil)
        withExtendedLifetime(root) {}
    }
}

@Suite struct FolderSummaryTests {
    @Test func totalsByKindAndLargestFiles() {
        let root = FileNode(name: "/r", isDirectory: true, children: [
            FileNode(name: "a.jpg", size: 500, isDirectory: false),
            FileNode(name: "sub", isDirectory: true, children: [
                FileNode(name: "b.mov", size: 900, isDirectory: false),
                FileNode(name: "c.jpg", size: 100, isDirectory: false),
                FileNode(name: "empty", isDirectory: true),
            ]),
            FileNode(name: "d.txt", size: 50, isDirectory: false),
        ])
        let summary = FolderSummary(of: root, largest: 2)
        #expect(summary.kinds == [
            .init(kind: .video, bytes: 900, files: 1),
            .init(kind: .image, bytes: 600, files: 2),
            .init(kind: .document, bytes: 50, files: 1),
        ])
        #expect(summary.largestFiles.map(\.name) == ["b.mov", "a.jpg"])
        #expect(summary.fileCount == 4)
        #expect(summary.folderCount == 2)
        withExtendedLifetime(root) {}
    }
}
