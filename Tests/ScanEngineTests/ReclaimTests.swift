import Darwin
import Foundation
import MacontrolCore
import ScanEngine
import Testing
import TestSupport

/// The size-accounting expectations (research/reports/topic-size-accounting.md, "Experiment"):
/// "frees now" counts only bytes that deleting the selection releases (F-0004).
@Suite struct ReclaimTests {
    private let mebibyte = 1 << 20

    @Test func cloneFreesNothingUntilItsWholeGroupIsSelected() async throws {
        let tmp = try TemporaryDirectory()
        let original = try tmp.file("pair/original.bin", size: 8 * mebibyte)
        let clone = try tmp.clone("pair/clone.bin", of: "pair/original.bin")
        let engine = ScanEngine()

        let one = try await engine.reclaimable([clone])
        let both = try await engine.reclaimable([original, clone])
        let folder = try await engine.reclaimable([tmp.url.appendingPathComponent("pair")])

        #expect(one == ReclaimEstimate(freesNow: 0, sharedElsewhere: UInt64(8 * mebibyte)))
        #expect(both == ReclaimEstimate(freesNow: UInt64(8 * mebibyte), sharedElsewhere: 0))
        #expect(folder == both)
    }

    @Test func partialCloneFreesOnlyItsRewrittenBytes() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("original.bin", size: 8 * mebibyte)
        let partial = try tmp.clone("partial.bin", of: "original.bin")
        let handle = try FileHandle(forUpdating: partial)
        try handle.seek(toOffset: UInt64(2 * mebibyte))
        try handle.write(contentsOf: Data(repeating: 0x55, count: mebibyte))
        try handle.synchronize()
        try handle.close()

        let estimate = try await ScanEngine().reclaimable([partial])

        #expect(estimate == ReclaimEstimate(freesNow: UInt64(mebibyte), sharedElsewhere: UInt64(7 * mebibyte)))
    }

    @Test func hardLinkFreesOnlyWhenEveryLinkIsSelected() async throws {
        let tmp = try TemporaryDirectory()
        let source = try tmp.file("a/source.bin", size: 4 * mebibyte)
        let link = try tmp.hardLink("b/link.bin", to: "a/source.bin")
        let engine = ScanEngine()

        #expect(try await engine.reclaimable([link]) == ReclaimEstimate(freesNow: 0, sharedElsewhere: UInt64(4 * mebibyte)))
        #expect(try await engine.reclaimable([source, link]) == ReclaimEstimate(freesNow: UInt64(4 * mebibyte), sharedElsewhere: 0))
        #expect(try await engine.reclaimable([tmp.url]) == ReclaimEstimate(freesNow: UInt64(4 * mebibyte), sharedElsewhere: 0))
    }

    /// F-0058: a firmlink alias of a selected item is the same item, not one more link.
    @Test func aliasedSelectionIsCountedOnce() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("dir/a.bin", size: mebibyte)
        try tmp.hardLink("dir/b.bin", to: "dir/a.bin")
        let folder = tmp.url.appendingPathComponent("dir")
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + folder.path)
        try #require(FileIdentity(url: alias) == FileIdentity(url: folder), "temp folder is not on the Data volume")

        let estimate = try await ScanEngine().reclaimable([folder, alias, alias.appendingPathComponent("a.bin")])

        #expect(estimate == ReclaimEstimate(freesNow: UInt64(mebibyte), sharedElsewhere: 0))
    }

    @Test func compressedFileFreesItsAllocatedSize() async throws {
        let tmp = try TemporaryDirectory()
        let plain = tmp.url.appendingPathComponent("plain.txt")
        try String(repeating: "macontrol compresses well. ", count: 400_000).write(to: plain, atomically: false, encoding: .utf8)
        let compressed = tmp.url.appendingPathComponent("compressed.txt")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--hfsCompression", plain.path, compressed.path]
        try ditto.run()
        ditto.waitUntilExit()
        let allocated = Fixtures.allocatedBytes(compressed)
        try #require(allocated > 0 && allocated < Fixtures.allocatedBytes(plain) / 10, "ditto did not compress")

        let estimate = try await ScanEngine().reclaimable([compressed])
        let tree = try await Fixtures.scanTree(tmp.url)

        #expect(estimate == ReclaimEstimate(freesNow: allocated, sharedElsewhere: 0))
        #expect(tree.flags(of: try #require(Fixtures.node("compressed.txt", in: tree))).contains(.compressed))
    }

    @Test func sparseFileFreesItsAllocatedBlocks() async throws {
        let tmp = try TemporaryDirectory()
        let sparse = try tmp.file("sparse.bin")
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.seek(toOffset: UInt64(100 * mebibyte - 1))
        try handle.write(contentsOf: Data([1]))
        try handle.close()

        let estimate = try await ScanEngine().reclaimable([sparse])

        #expect(estimate.freesNow == Fixtures.allocatedBytes(sparse))
        #expect(estimate.freesNow < UInt64(mebibyte))
    }

    @Test func unreadableFolderMakesTheEstimateALowerBound() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("sel/locked/secret.bin", size: 8192)
        try tmp.file("sel/visible.bin", size: 8192)
        chmod(tmp.url.appendingPathComponent("sel/locked").path, 0)

        let estimate = try await ScanEngine().reclaimable([tmp.url.appendingPathComponent("sel")])

        #expect(estimate == ReclaimEstimate(freesNow: 8192, sharedElsewhere: 0, isIncomplete: true))
    }

    @Test func missingItemsFreeNothing() async throws {
        let tmp = try TemporaryDirectory()
        let estimate = try await ScanEngine().reclaimable([tmp.url.appendingPathComponent("gone")])
        #expect(estimate == ReclaimEstimate(freesNow: 0, sharedElsewhere: 0))
    }
}
