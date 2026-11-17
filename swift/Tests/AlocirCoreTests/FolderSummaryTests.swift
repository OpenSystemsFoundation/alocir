import Testing
@testable import AlocirCore

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
