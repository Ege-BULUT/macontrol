import Darwin
import Foundation
import MacontrolCore
@testable import ScanEngine
import Testing
import TestSupport

/// Running the whole process out of descriptors (F-0060). The squeeze is process-wide and would starve
/// tests running alongside, so these run on their own:
///   MACONTROL_FD_PRESSURE=1 swift test --filter DescriptorPressureTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACONTROL_FD_PRESSURE"] != nil))
struct DescriptorPressureTests {
    /// Several walks whose budgets add up to more than the process may open: the cleaner's parallel
    /// measures on a Mac whose limit could not be raised. A walk that meets EMFILE while reopening a
    /// spilled folder must wait for descriptors like a first open does, not flag the folder.
    @Test func concurrentWalksOverTheProcessLimitStayExact() async throws {
        let tmp = try TemporaryDirectory()
        _ = try Fixtures.makeBushyTree(tmp, under: "bush", width: 4, depth: 6)
        let bush = tmp.url.appendingPathComponent("bush")
        let options = ScanOptions(workerCount: 12, descriptorBudget: 48)
        let expected = try await ScanEngine(options: options).measure(bush)
        try #require(!expected.isIncomplete)

        var saved = rlimit()
        getrlimit(RLIMIT_NOFILE, &saved)
        var low = saved
        low.rlim_cur = 96
        try #require(setrlimit(RLIMIT_NOFILE, &low) == 0)
        defer { setrlimit(RLIMIT_NOFILE, &saved) }

        for _ in 0..<3 {
            let results = try await withThrowingTaskGroup(of: ItemMeasurement.self) { group in
                for _ in 0..<5 { group.addTask { try await ScanEngine(options: options).measure(bush) } }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(results.allSatisfy { $0 == expected }, "\(results.filter(\.isIncomplete).count) of 5 incomplete")
        }
    }
}
