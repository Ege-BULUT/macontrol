import Darwin
import Foundation
import MacontrolCore
@testable import ScanEngine
import Testing
import TestSupport

@Suite struct ScanEngineTests {
    @Test func hardLinkedBytesAreCountedOnce() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("a/data.bin", size: 1 << 20)
        try tmp.hardLink("b/data.bin", to: "a/data.bin")
        try tmp.file("c/small.txt", size: 10)

        let tree = try await Fixtures.scanTree(tmp.url)

        #expect(tree.allocatedSize(of: ScanTree.root) == (1 << 20) + 4096)
        #expect(tree.fileCount(of: ScanTree.root) == 3)
    }

    /// T-0063: running sizes from a real walk add up to what the completed scan reports, top-level item by item.
    @Test func previewOfAFinishedWalkMatchesTheCompletedScan() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("top.bin", size: 50_000)
        try tmp.file("a/one.bin", size: 1 << 20)
        try tmp.file("a/b/c/two.bin", size: 300_000)
        _ = try Fixtures.makeBushyTree(tmp, under: "noise", width: 3, depth: 3)
        try tmp.directory("empty")
        let identity = try #require(FileIdentity(url: tmp.url))
        let sink = TreeSink(tree: ScanTree(rootURL: tmp.url, rootIdentity: identity), dataVolume: nil)

        try ScanEngine.walk([WalkRoot(path: tmp.url.path, identity: identity, node: 0)], sink: sink, options: ScanOptions(), cancellation: Cancellation())
        let preview = sink.preview()
        let completed = try await Fixtures.scanTree(tmp.url)

        func topLevel(_ tree: ScanTree) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: tree.children(of: ScanTree.root).map { (tree.name(of: $0), tree.allocatedSize(of: $0)) })
        }
        #expect(topLevel(preview) == topLevel(completed))
        #expect(preview.allocatedSize(of: ScanTree.root) == completed.allocatedSize(of: ScanTree.root))
    }

    /// The progress bar's goal for a whole volume: its own bytes in use, never a folder's volume.
    @Test func volumeBytesInUseOnlyForAVolumeRoot() throws {
        let tmp = try TemporaryDirectory()
        #expect(ScanEngine.volumeBytesInUse(at: tmp.url) == nil)
        let data = try #require(ScanEngine.volumeBytesInUse(at: URL(fileURLWithPath: "/System/Volumes/Data")))
        #expect(data > 0)
        // Other processes write meanwhile; the System volume alone would be off by gigabytes the other way.
        let slash = try #require(ScanEngine.volumeBytesInUse(at: URL(fileURLWithPath: "/")))
        #expect(slash.distance(to: data).magnitude < 1 << 30, "\"/\" is scanned as the Data volume")
    }

    /// F-0054, F-0010: the link with the smallest path keeps the bytes in every run, whichever link a worker met first.
    @Test func hardLinkOwnerIsTheSmallestPathInEveryRun() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("m/shared.bin", size: 1 << 20)
        try tmp.hardLink("b/link.bin", to: "m/shared.bin")
        try tmp.hardLink("z/link.bin", to: "m/shared.bin")
        try tmp.file("b/own.bin", size: 8192)
        _ = try Fixtures.makeBushyTree(tmp, under: "noise", width: 3, depth: 3)

        var sizes: Set<[[UInt8]: UInt64]> = []
        for _ in 0..<20 {
            let tree = try await Fixtures.scanTree(tmp.url)
            let owner = try #require(Fixtures.node("b/link.bin", in: tree))
            #expect(tree.allocatedSize(of: owner) == 1 << 20)
            #expect(!tree.flags(of: owner).contains(.sharedHardLink))
            for other in ["m/shared.bin", "z/link.bin"] {
                let node = try #require(Fixtures.node(other, in: tree))
                #expect(tree.flags(of: node).isSuperset(of: [.hardLinked, .sharedHardLink]))
                #expect(tree.allocatedSize(of: node) == 0)
            }
            sizes.insert(Fixtures.folderSizes(tree))
        }
        #expect(sizes.count == 1, "per-folder sizes differ between runs")
    }

    /// F-0008: a path longer than PATH_MAX is walked and counted, because every open is relative to its parent.
    @Test func pathLongerThanPathMaxIsCounted() async throws {
        let tmp = try TemporaryDirectory()
        let name = String(repeating: "p", count: 200)
        try tmp.directory("deep")
        try Fixtures.makeChain(in: tmp.url.appendingPathComponent("deep"), name: name, depth: 6, fileSize: 1 << 20)
        defer { Fixtures.cutChain(in: tmp.url.appendingPathComponent("deep"), name: name, depth: 6, every: 3, root: tmp.url) }

        let tree = try await Fixtures.scanTree(tmp.url)

        #expect(tree.allocatedSize(of: ScanTree.root) == 1 << 20)
        let bottom = try #require((0..<tree.count).first { tree.name(of: $0) == "bottom.bin" })
        #expect(tree.relativePathBytes(of: bottom).count > Int(PATH_MAX))
        #expect((0..<tree.count).allSatisfy { tree.flags(of: $0).isDisjoint(with: [.unreadable, .incomplete]) })
    }

    /// F-0044: nesting depth is limited by nothing but memory; 4,000 levels is a path of 8,000 bytes.
    @Test func fourThousandLevelsOfNesting() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.directory("nest")
        try Fixtures.makeChain(in: tmp.url.appendingPathComponent("nest"), name: "d", depth: 4000, fileSize: 5000)
        defer { Fixtures.cutChain(in: tmp.url.appendingPathComponent("nest"), name: "d", depth: 4000, every: 300, root: tmp.url) }

        let tree = try await Fixtures.scanTree(tmp.url, options: ScanOptions(descriptorBudget: 16))
        let measurement = try await ScanEngine(options: ScanOptions(descriptorBudget: 16)).measure(tmp.url)

        #expect(tree.count == 1 + 1 + 4000 + 1)
        #expect(tree.allocatedSize(of: ScanTree.root) == 8192)
        #expect(measurement.allocated == 8192)
        #expect(measurement.fileCount == 1)
    }

    /// F-0057: an unreadable folder is flagged, never shown as an empty 0 B folder.
    @Test func unreadableFolderIsFlagged() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("locked/secret.bin", size: 50_000)
        try tmp.file("open/visible.bin", size: 4096)
        chmod(tmp.url.appendingPathComponent("locked").path, 0)

        let tree = try await Fixtures.scanTree(tmp.url)
        let measurement = try await ScanEngine().measure(tmp.url)

        let locked = try #require(Fixtures.node("locked", in: tree))
        #expect(tree.flags(of: locked).contains(.unreadable))
        #expect(!tree.flags(of: try #require(Fixtures.node("open", in: tree))).contains(.unreadable))
        #expect(tree.allocatedSize(of: ScanTree.root) == 4096)
        #expect(measurement.isIncomplete)
    }

    @Test func symlinkLoopsAreNotFollowed() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("real/data.bin", size: 8192)
        try tmp.symlink("real/self", to: ".")
        try tmp.symlink("real/up", to: "..")
        try tmp.symlink("a", to: "b")
        try tmp.symlink("b", to: "a")
        try tmp.symlink("outside", to: "/")

        let tree = try await Fixtures.scanTree(tmp.url)

        #expect(tree.allocatedSize(of: ScanTree.root) == 8192)
        let loop = try #require(Fixtures.node("real/self", in: tree))
        #expect(tree.flags(of: loop).contains(.symlink))
        #expect(tree.children(of: loop).isEmpty)
        #expect(tree.count == 1 + 1 + 3 + 3)
    }

    /// F-0060: a descriptor budget far below the tree's depth of held parents still gives the exact total,
    /// by closing idle parents and reopening them by name later.
    @Test func tinyDescriptorBudgetGivesTheExactTotal() async throws {
        let tmp = try TemporaryDirectory()
        let files = try Fixtures.makeBushyTree(tmp, under: "bush", width: 3, depth: 6)
        let reference = try await Fixtures.scanTree(tmp.url)

        let root = try #require(FileIdentity(url: tmp.url))
        let sink = TreeSink(tree: ScanTree(rootURL: tmp.url, rootIdentity: root), dataVolume: nil)
        let walk = FolderWalk(roots: [WalkRoot(path: tmp.url.path, identity: root, node: 0)], sink: sink, workers: 4, descriptorBudget: 6)
        walk.run()
        sink.tree.finalizeTotals()

        #expect(walk.reopenCount > 0, "the budget never forced a reopen, so this test proves nothing")
        #expect(sink.tree.fileCount(of: ScanTree.root) == files)
        #expect(sink.tree.allocatedSize(of: ScanTree.root) == UInt64(files) * 4096)
        #expect(Fixtures.folderSizes(sink.tree) == Fixtures.folderSizes(reference))
    }

    /// F-0028: bundles are sized in full and marked as one item.
    @Test func packagesAreSizedInFull() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("Demo.app/Contents/MacOS/Demo", size: 100_000)
        try tmp.file("Demo.app/Contents/Resources/icon.icns", size: 30_000)
        try tmp.file("plain.folder.v2/readme.txt", size: 10)

        let tree = try await Fixtures.scanTree(tmp.url)

        let app = try #require(Fixtures.node("Demo.app", in: tree))
        #expect(tree.flags(of: app).contains(.package))
        #expect(tree.allocatedSize(of: app) == 102_400 + 32_768)
        #expect(!tree.flags(of: try #require(Fixtures.node("plain.folder.v2", in: tree))).contains(.package))
    }

    /// F-0031: another volume mounted inside the scanned folder is a leaf, never entered.
    @Test func mountPointsAreLeaves() async throws {
        let tree = try await Fixtures.scanTree(URL(fileURLWithPath: "/System/Volumes"))

        let data = try #require(Fixtures.node("Data", in: tree))
        #expect(tree.flags(of: data).contains(.mountPoint))
        #expect(tree.children(of: data).isEmpty)
        #expect(tree.allocatedSize(of: data) == 0)
    }

    @Test func measureMatchesTheTreeTotal() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("x/1.bin", size: 50_000)
        try tmp.file("x/y/2.bin", size: 9000)
        try tmp.hardLink("x/y/3.bin", to: "x/1.bin")

        let measurement = try await ScanEngine().measure(tmp.url.appendingPathComponent("x"))
        let tree = try await Fixtures.scanTree(tmp.url.appendingPathComponent("x"))

        #expect(measurement.allocated == 53_248 + 12_288)
        #expect(measurement.allocated == tree.allocatedSize(of: ScanTree.root))
        #expect(measurement.fileCount == tree.fileCount(of: ScanTree.root))
        #expect(!measurement.isIncomplete)
        let newest = try #require(measurement.newestModification)
        #expect(abs(newest.timeIntervalSinceNow) < 600)
    }

    @Test func measureOfAFileAndOfAMissingItem() async throws {
        let tmp = try TemporaryDirectory()
        let file = try tmp.file("one.bin", size: 5000)

        #expect(try await ScanEngine().measure(file).allocated == 8192)
        await #expect(throws: POSIXError.self) { try await ScanEngine().measure(tmp.url.appendingPathComponent("missing")) }
    }

    @Test func scanningAFileIsAnError() async throws {
        let tmp = try TemporaryDirectory()
        let file = try tmp.file("one.bin", size: 5000)
        await #expect(throws: ScanError.notADirectory(file)) { _ = try await Fixtures.scanTree(file) }
    }

    @Test func endingTheStreamStopsTheWalk() async throws {
        let tmp = try TemporaryDirectory()
        _ = try Fixtures.makeBushyTree(tmp, under: "bush", width: 4, depth: 5)
        let task = Task {
            var events = 0
            for try await _ in ScanEngine(options: ScanOptions(workerCount: 1)).scan(tmp.url) { events += 1 }
            return events
        }
        task.cancel()
        _ = try? await task.value  // finishing at all is the assertion: the walk thread saw the cancellation
    }

    @Test func workerPolicyIsParallel() {
        #expect(ScanOptions().resolvedWorkerCount >= min(2, ProcessInfo.processInfo.activeProcessorCount))
        #expect(ScanOptions(workerCount: 3).resolvedWorkerCount == 3)
    }
}
