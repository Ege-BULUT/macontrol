import Darwin
import Foundation
import MacontrolCore
@testable import ScanEngine
import Testing

/// How listings become tree nodes, fed with hand-made listings so no real volume is walked.
@Suite struct TreeSinkTests {
    private func listing(_ entries: [(String, BulkEntry)]) -> Listing {
        var listing = Listing()
        for (name, template) in entries {
            var entry = template
            entry.nameStart = listing.names.count
            entry.nameLength = name.utf8.count
            listing.names.append(contentsOf: name.utf8)
            listing.entries.append(entry)
        }
        return listing
    }

    private func folder(inode: UInt64, flags: UInt32 = 0) -> BulkEntry {
        BulkEntry(nameStart: 0, nameLength: 0, device: 1, type: UInt32(VDIR.rawValue), fileFlags: flags, inode: inode)
    }

    private func file(inode: UInt64, allocated: UInt64, flags: UInt32 = 0) -> BulkEntry {
        BulkEntry(nameStart: 0, nameLength: 0, device: 1, type: UInt32(VREG.rawValue), fileFlags: flags, inode: inode, logical: allocated, allocated: allocated)
    }

    /// F-0031, F-0005: "/" is the Data volume walked once. Firmlinked entries appear at their "/" paths;
    /// Data-only folders such as "macOS Install Data" appear under /System/Volumes/Data, where they exist.
    @Test func dataVolumeRootIsPlacedAtUserFacingPaths() throws {
        let layout = try #require(DataVolumeLayout(firmlinks: "/Users\tUsers\n/System/Library/Caches\tSystem/Library/Caches\n/usr/local\tusr/local\n"))
        let sink = TreeSink(tree: ScanTree(rootURL: URL(fileURLWithPath: "/"), rootIdentity: FileIdentity(device: 1, inode: 2)), dataVolume: layout)
        let entries = listing([
            ("macOS Install Data", folder(inode: 10)),
            ("Users", folder(inode: 11)),
            ("System", folder(inode: 12)),
            (".Spotlight-V100", folder(inode: 13)),
            ("usr", folder(inode: 14)),
            ("leftover.log", file(inode: 15, allocated: 4096)),
        ])
        var walkable: [Int32] = []

        sink.add(entries, to: 0, walkableNodes: &walkable)

        let paths = walkable.map { sink.tree.url(of: Int($0)).path }
        #expect(paths == ["/System/Volumes/Data/macOS Install Data", "/Users", "/System", "/System/Volumes/Data/.Spotlight-V100", "/usr"])
        let data = try #require(sink.tree.parent(of: Int(walkable[0])))
        #expect(sink.tree.url(of: data).path == "/System/Volumes/Data")
        #expect(sink.tree.children(of: ScanTree.root).count == 3, "Users, System, usr; nothing else at the top")
        let preview = sink.preview()
        let system = try #require(preview.children(of: ScanTree.root).first { preview.name(of: $0) == "System" })
        #expect(preview.allocatedSize(of: system) == 4096, "leftover.log lives under /System/Volumes/Data")
    }

    /// The app's Macintosh HD scope passes the Data volume and a user may pick "/": both are the startup
    /// disk shown at user-facing paths, while a folder inside either is scanned as it is.
    @Test func dataVolumeAndSlashAreBothTheStartupDisk() {
        #expect(DataVolumeLayout.forStartupDisk("/System/Volumes/Data") != nil)
        #expect(DataVolumeLayout.forStartupDisk("/") != nil)
        #expect(DataVolumeLayout.forStartupDisk("/System/Volumes/Data/Users") == nil)
        #expect(DataVolumeLayout.forStartupDisk("/Users") == nil)
    }

    /// F-0019: an evicted iCloud item counts 0 B here and is never listed (listing would download it).
    @Test func datalessItemsAreZeroAndNotEntered() {
        let sink = TreeSink(tree: ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 2)), dataVolume: nil)
        let dataless = UInt32(SF_DATALESS)
        var walkable: [Int32] = []

        sink.add(listing([
            ("cloud.mov", file(inode: 3, allocated: 1 << 30, flags: dataless)),
            ("CloudFolder", folder(inode: 4, flags: dataless)),
            ("System Thing", folder(inode: 5, flags: UInt32(SF_RESTRICTED))),
        ]), to: 0, walkableNodes: &walkable)
        sink.tree.finalizeTotals()

        #expect(sink.tree.allocatedSize(of: ScanTree.root) == 0)
        #expect(sink.tree.children(of: 0).allSatisfy { sink.tree.flags(of: $0).contains(.dataless) || sink.tree.flags(of: $0).contains(.systemProtected) })
        #expect(walkable.count == 1, "only the restricted folder is listed; the dataless one is not")
    }

    /// T-0063: while the walk runs, each top-level item only grows, and once every listing is in, the preview
    /// holds the finished tree's top-level sizes.
    @Test func previewSizesOnlyGrowAndEndAtTheFinishedTotals() {
        let sink = TreeSink(tree: ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 2)), dataVolume: nil)
        var walkable: [Int32] = []
        func sizes() -> [String: UInt64] {
            let preview = sink.preview()
            return Dictionary(uniqueKeysWithValues: preview.children(of: ScanTree.root).map { (preview.name(of: $0), preview.allocatedSize(of: $0)) })
        }
        sink.add(listing([("A", folder(inode: 3)), ("B", folder(inode: 4)), ("top.bin", file(inode: 5, allocated: 100))]), to: 0, walkableNodes: &walkable)
        let (a, b) = (walkable[0], walkable[1])
        var previews = [sizes()]
        walkable = []
        sink.add(listing([("a1.bin", file(inode: 6, allocated: 10)), ("A1", folder(inode: 7)), ("a2.bin", file(inode: 8, allocated: 20))]), to: a, walkableNodes: &walkable)
        previews.append(sizes())
        let a1 = walkable[0]
        sink.add(listing([("deep.bin", file(inode: 9, allocated: 5))]), to: a1, walkableNodes: &walkable)
        previews.append(sizes())
        sink.add(listing([("b1.bin", file(inode: 10, allocated: 7))]), to: b, walkableNodes: &walkable)
        previews.append(sizes())

        for (earlier, later) in zip(previews, previews.dropFirst()) {
            #expect(earlier.allSatisfy { later[$0.key, default: 0] >= $0.value }, "\(earlier) -> \(later)")
        }
        sink.tree.finalizeTotals()
        let finished = Dictionary(uniqueKeysWithValues: sink.tree.children(of: ScanTree.root).map { (sink.tree.name(of: $0), sink.tree.allocatedSize(of: $0)) })
        #expect(previews.last == finished)
        #expect(finished == ["A": 35, "B": 7, "top.bin": 100])
    }

    /// T-0063: the finished tree charges a hard-linked file once, to its smallest path. Running totals leave
    /// such files out, so neither the preview nor the progress bytes pass it: counting every link put a
    /// node_modules 53% over its final size.
    @Test func runningTotalsLeaveOutHardLinksAndNeverPassTheFinishedTree() {
        let sink = TreeSink(tree: ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 2)), dataVolume: nil)
        var walkable: [Int32] = []
        var linked = file(inode: 9, allocated: 1000)
        linked.linkCount = 3
        sink.add(listing([("A", folder(inode: 3)), ("B", folder(inode: 4)), ("top-link", linked)]), to: 0, walkableNodes: &walkable)
        let (a, b) = (walkable[0], walkable[1])
        sink.add(listing([("link", linked), ("own.bin", file(inode: 5, allocated: 10))]), to: a, walkableNodes: &walkable)
        sink.add(listing([("link", linked)]), to: b, walkableNodes: &walkable)
        let preview = sink.preview()
        let running = sink.progress.bytesVisited
        sink.tree.finalizeTotals()

        let shown = Dictionary(uniqueKeysWithValues: preview.children(of: ScanTree.root).map { (preview.name(of: $0), preview.allocatedSize(of: $0)) })
        let finished = Dictionary(uniqueKeysWithValues: sink.tree.children(of: ScanTree.root).map { (sink.tree.name(of: $0), sink.tree.allocatedSize(of: $0)) })
        #expect(finished == ["A": 1010, "B": 0, "top-link": 0], "A/link is the smallest path")
        #expect(shown.allSatisfy { $0.value <= finished[$0.key, default: 0] }, "\(shown) vs \(finished)")
        #expect(running <= sink.tree.allocatedSize(of: ScanTree.root), "\(running)")
    }

    @Test func mountPointEntryIsALeafWithItsFlag() {
        let sink = TreeSink(tree: ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 2)), dataVolume: nil)
        var mount = folder(inode: 3)
        mount.mountStatus = UInt32(DIR_MNTSTATUS_MNTPOINT)
        var walkable: [Int32] = []

        sink.add(listing([("Volume", mount)]), to: 0, walkableNodes: &walkable)

        #expect(walkable.isEmpty)
        #expect(sink.tree.flags(of: 1).isSuperset(of: [.directory, .mountPoint]))
    }
}
