import Foundation
import MacontrolCore
import ScanEngine
import Testing
import TestSupport

@Suite struct ScanEngineTests {
    private func scanTree(_ root: URL) async throws -> ScanTree {
        for try await event in ScanEngine().scan(root) {
            if case .completed(let tree) = event { return tree }
        }
        throw CancellationError()
    }

    @Test func hardLinkedBytesAreCountedOnce() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("a/data.bin", size: 1 << 20)
        try tmp.hardLink("b/data.bin", to: "a/data.bin")
        try tmp.file("c/small.txt", size: 10)

        let tree = try await scanTree(tmp.url)

        #expect(tree.allocatedSize(of: ScanTree.root) == (1 << 20) + 4096)
        #expect(tree.fileCount(of: ScanTree.root) == 3)
    }

    @Test func measureMatchesTheTreeTotal() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("x/1.bin", size: 50_000)
        try tmp.file("x/y/2.bin", size: 9000)

        let measurement = try await ScanEngine().measure(tmp.url.appendingPathComponent("x"))

        #expect(measurement.allocated == 53_248 + 12_288)
        #expect(measurement.fileCount == 2)
        #expect(!measurement.isIncomplete)
    }
}
