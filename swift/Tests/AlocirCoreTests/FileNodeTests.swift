import Testing
@testable import AlocirCore

@Suite struct FileNodeTests {
    @Test func directorySizeIsSumOfChildrenSortedLargestFirst() {
        let root = FileNode(name: "/tmp/root", isDirectory: true, children: [
            FileNode(name: "a", size: 10, isDirectory: false),
            FileNode(name: "b", size: 30, isDirectory: false),
            FileNode(name: "c", size: 20, isDirectory: false),
        ])
        #expect(root.size == 60)
        #expect(root.children.map(\.name) == ["b", "c", "a"])
        #expect(root.children.allSatisfy { $0.parent === root })
    }

    @Test func pathJoinsFromRoot() {
        let leaf = FileNode(name: "leaf.txt", size: 1, isDirectory: false)
        let root = FileNode(name: "/tmp/root", isDirectory: true, children: [
            FileNode(name: "sub", isDirectory: true, children: [leaf]),
        ])
        #expect(leaf.path == "/tmp/root/sub/leaf.txt")
        #expect(root.path == "/tmp/root")
        #expect(root.nodeCount == 3)
    }

    @Test func rootSlashIsNotDoubled() {
        let leaf = FileNode(name: "Users", isDirectory: true)
        // `parent` is unowned(unsafe): the root must stay alive while its
        // children are used, so hold it for the whole test.
        let root = FileNode(name: "/", isDirectory: true, children: [leaf])
        withExtendedLifetime(root) {
            #expect(leaf.path == "/Users")
        }
    }
}
