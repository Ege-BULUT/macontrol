import Foundation
import MacontrolCore
import ScanEngine
import Testing

/// Acceptance on the 300k-file bench fixture (research/bench/make_fixture.sh), read-only. Run with
///   MACONTROL_BENCH_FIXTURE=research/bench/fixtures/tree swift test --filter BenchFixtureTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_BENCH_FIXTURE"] != nil))
struct BenchFixtureTests {
    /// `visible_to_non_root.allocated_all` in fixtures/ground_truth.json.
    static let groundTruth: UInt64 = 2_368_040_960

    /// F-0007, F-0008, F-0054: the exact ground truth, and the same size for every folder, in 20 runs.
    @Test func totalAndEveryFolderAreIdenticalOverTwentyRuns() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACONTROL_BENCH_FIXTURE"])
        let root = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        var reference: [[UInt8]: UInt64]?
        for run in 1...20 {
            let tree = try await Fixtures.scanTree(root.absoluteURL)
            #expect(tree.allocatedSize(of: ScanTree.root) == Self.groundTruth, "run \(run)")
            let sizes = Fixtures.folderSizes(tree)
            if let reference {
                #expect(sizes == reference, "run \(run): per-folder sizes changed")
            } else {
                reference = sizes
            }
        }
    }
}
