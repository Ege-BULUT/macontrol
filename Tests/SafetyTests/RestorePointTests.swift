import Foundation
@testable import Safety
import Testing

@Suite struct RestorePointTests {
    /// What `tmutil localsnapshot` printed on this Mac (feasibility-permanent, tmutil-run.log, 2026-09-23).
    static let captured = """
        NOTE: local snapshots are considered purgeable and may be removed at any time by deleted(8).
        Created local snapshot with date: 2026-09-23-152529

        """

    @Test func theSnapshotNameComesFromTmutilsOutput() {
        #expect(RestorePoint.snapshotName(in: Self.captured) == "com.apple.TimeMachine.2026-09-23-152529.local")
        #expect(RestorePoint.snapshotName(in: "Created local snapshot with date: 2026-09-23-152529") != nil)
    }

    @Test(arguments: [
        "", "NOTE: local snapshots are considered purgeable and may be removed at any time by deleted(8).",
        "Failed to create local snapshot", "Created local snapshot with date: 2026-09-23", "Created local snapshot with date: $(date)",
    ])
    func outputWithoutASnapshotGivesNoName(output: String) {
        #expect(RestorePoint.snapshotName(in: output) == nil)
    }

    /// A tool that hangs (sleep stands in for tmutil) is stopped at the timeout, and the error says so; one that
    /// finishes gives its status and output. Only the message is asserted: under the full suite's load the stop
    /// came 12 s late once, and without the stop sleep ends normally after 30 s and nothing is thrown.
    @Test func aHungToolIsStoppedAtTheTimeout() async throws {
        await #expect {
            _ = try await RestorePoint.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 1)
        } throws: { error in
            (error as NSError).localizedDescription == "sleep did not finish in 1 seconds, so it was stopped."
        }
        let finished = try await RestorePoint.run(URL(fileURLWithPath: "/bin/echo"), ["done"], timeout: 30)
        #expect(finished.status == 0 && finished.text == "done\n")
    }

    /// Makes a real local snapshot of this Mac's Data volume (about a minute), so only on request. Delete it
    /// afterwards with `tmutil deletelocalsnapshots <date>`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_TMUTIL"] == "1"))
    func createMakesALocalSnapshot() async throws {
        let name = try await RestorePoint.create()
        #expect(name.hasPrefix("com.apple.TimeMachine.") && name.hasSuffix(".local"))
    }
}
