import Foundation
import MacontrolCore
import Testing

@Suite struct ScanTreeTests {
    private func sampleTree() -> (ScanTree, folder: Int, shared: Int) {
        var tree = ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 1))
        let folder = tree.addChild(of: ScanTree.root, name: "a", flags: .directory, allocated: 0, logical: 0, identity: FileIdentity(device: 1, inode: 2))
        tree.addChild(of: folder, name: "big", flags: [], allocated: 4096 * 10, logical: 40_000, identity: FileIdentity(device: 1, inode: 3))
        let shared = tree.addChild(
            of: folder, name: "link", flags: [.hardLinked, .sharedHardLink], allocated: 0, logical: 8192,
            identity: FileIdentity(device: 1, inode: 4)
        )
        tree.addChild(of: ScanTree.root, name: "b", flags: [], allocated: 4096, logical: 10, identity: FileIdentity(device: 1, inode: 5))
        tree.finalizeTotals()
        return (tree, folder, shared)
    }

    @Test func totalsRollUpIntoAncestors() {
        let (tree, folder, _) = sampleTree()
        #expect(tree.allocatedSize(of: folder) == 40_960)
        #expect(tree.allocatedSize(of: ScanTree.root) == 45_056)
        #expect(tree.fileCount(of: ScanTree.root) == 3)
        #expect(tree.url(of: folder).path == "/x/a")
    }

    @Test func removingASharedLinkSubtractsOnlyItsChargedBytes() {
        var (tree, folder, shared) = sampleTree()
        tree.removeSubtree(at: shared)
        #expect(tree.allocatedSize(of: folder) == 40_960)
        #expect(tree.fileCount(of: folder) == 1)
        #expect(!tree.children(of: folder).contains(shared))
    }

    @Test func removingAFolderSplicesItOut() {
        var (tree, folder, _) = sampleTree()
        tree.removeSubtree(at: folder)
        #expect(tree.allocatedSize(of: ScanTree.root) == 4096)
        #expect(tree.children(of: ScanTree.root).count == 1)
        tree.removeSubtree(at: folder)
        #expect(tree.allocatedSize(of: ScanTree.root) == 4096, "a second removal changes nothing")
    }
}
