import Foundation
import MacontrolCore
@testable import MacontrolUI

/// Synthetic scan trees for the disk map tests. Roots point at a path that does not exist, so any
/// test that passes proves the code under test never reads the disk.
nonisolated enum DiskMapFixtures {
    static let missingRoot = URL(fileURLWithPath: "/nonexistent-macontrol-fixture")

    struct Builder {
        var tree: ScanTree
        private var inode: UInt64 = 1

        init(root: URL = DiskMapFixtures.missingRoot) {
            tree = ScanTree(rootURL: root, rootIdentity: FileIdentity(device: 1, inode: 1))
        }

        @discardableResult
        mutating func folder(_ parent: Int, _ name: String, ownBytes: UInt64 = 0, flags: NodeFlags = []) -> Int {
            add(parent, name, bytes: ownBytes, flags: flags.union(.directory))
        }

        @discardableResult
        mutating func file(_ parent: Int, _ name: String, _ bytes: UInt64, flags: NodeFlags = []) -> Int {
            add(parent, name, bytes: bytes, flags: flags)
        }

        mutating func add(_ parent: Int, _ name: String, bytes: UInt64, flags: NodeFlags, identity: FileIdentity? = nil) -> Int {
            inode += 1
            return tree.addChild(
                of: parent, name: name, flags: flags, allocated: bytes, logical: bytes,
                identity: identity ?? FileIdentity(device: 1, inode: inode)
            )
        }

        func finished() -> ScanTree {
            var tree = tree
            tree.finalizeTotals()
            return tree
        }
    }

    /// A seeded tree with mixed sizes, empty files, folders with their own bytes, packages and
    /// unreadable folders, a few levels deep.
    static func mixed(seed: UInt64 = 7, folders: Int = 60) -> ScanTree {
        var builder = Builder()
        var random = SeededRandom(seed: seed)
        var open = [(ScanTree.root, 0)]
        var made = 0
        while let (parent, depth) = open.popLast(), made < folders {
            for index in 0..<random.next(in: 2...40) {
                let roll = random.next(in: 0...99)
                if roll < 18, depth < 5 {
                    made += 1
                    let flags: NodeFlags = roll < 2 ? .package : (roll < 4 ? .unreadable : [])
                    let folder = builder.folder(parent, "folder-\(made)", ownBytes: roll.isMultiple(of: 3) ? 4_096 : 0, flags: flags)
                    open.insert((folder, depth + 1), at: 0)
                } else {
                    let bytes: UInt64 = roll > 95 ? 0 : UInt64(pow(10, Double(random.next(in: 20...100)) / 10))
                    builder.file(parent, "file-\(parent)-\(index)", bytes)
                }
            }
        }
        return builder.finished()
    }

    /// `depth` folders nested in one chain, with a file at the bottom.
    static func chain(depth: Int) -> ScanTree {
        var builder = Builder()
        var parent = ScanTree.root
        for level in 1...depth { parent = builder.folder(parent, "level-\(level)") }
        builder.file(parent, "bottom.bin", 1_000_000)
        return builder.finished()
    }

    static func key(_ style: MapStyle, focus: Int = ScanTree.root, width: Int = 800, height: Int = 600, scale: Double = 2, version: Int = 0) -> LayoutKey {
        LayoutKey(treeVersion: version, focus: focus, style: style, width: width, height: height, scale: scale)
    }
}

nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return range.lowerBound + Int((state >> 33) % UInt64(range.count))
    }
}
