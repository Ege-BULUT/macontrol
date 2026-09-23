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

    /// F-0054: which link keeps the bytes depends only on paths, never on the order links were added.
    @Test func smallestPathKeepsHardLinkBytesInAnyInsertionOrder() {
        for order in [["b", "a", "c"], ["c", "b", "a"], ["a", "c", "b"]] {
            var tree = ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 1))
            var links: [String: Int] = [:]
            for name in order {
                links[name] = tree.addChild(
                    of: ScanTree.root, name: name, flags: .hardLinked, allocated: 8192, logical: 8000, identity: FileIdentity(device: 1, inode: 9)
                )
            }
            tree.finalizeTotals()
            #expect(tree.allocatedSize(of: ScanTree.root) == 8192)
            #expect(tree.logicalSize(of: ScanTree.root) == 8000)
            #expect(tree.allocatedSize(of: links["a"]!) == 8192)
            #expect(tree.flags(of: links["b"]!).contains(.sharedHardLink))
            #expect(tree.flags(of: links["c"]!).contains(.sharedHardLink))
        }
    }

    /// Names are kept as the file system's bytes: NFC and NFD spellings stay two different names.
    @Test func namesKeepTheirExactBytes() {
        var tree = ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 1))
        let nfc = tree.addChild(of: ScanTree.root, name: "caf\u{E9}", flags: [], allocated: 0, logical: 0, identity: FileIdentity(device: 1, inode: 2))
        let nfd = tree.addChild(of: ScanTree.root, name: "cafe\u{301}", flags: [], allocated: 0, logical: 0, identity: FileIdentity(device: 1, inode: 3))
        #expect(tree.relativePathBytes(of: nfc) != tree.relativePathBytes(of: nfd))
        #expect(tree.name(of: nfd).unicodeScalars.count == 5)
        #expect(tree.name(of: nfc).unicodeScalars.count == 4)
    }

    /// F-0041: under 80 bytes per node plus name bytes, array slack included.
    @Test func storageStaysUnderEightyBytesPerNode() {
        var tree = ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 1))
        var nameBytes = 0
        for index in 0..<100_000 {
            let name = "file-\(index).dat"
            nameBytes += name.utf8.count
            tree.addChild(of: ScanTree.root, name: name, flags: [], allocated: 4096, logical: 100, identity: FileIdentity(device: 1, inode: UInt64(index + 2)))
        }
        #expect(ScanTree.bytesPerNode < 80)
        #expect((tree.storageBytes - nameBytes) / tree.count < 80 + ScanTree.bytesPerNode / 2, "slack from array growth only")
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
