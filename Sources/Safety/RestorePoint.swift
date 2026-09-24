import Foundation
import os

/// A local APFS snapshot taken before a permanent batch, only when the user ticks the box (DESIGN-debloat section 2.6).
/// Unprivileged, no Time Machine destination needed (feasibility-permanent fact 20). macOS may purge it at any time,
/// and while it exists the deleted items keep their space.
public enum RestorePoint {
    /// Runs `/usr/bin/tmutil localsnapshot` (an argument array, no shell; about a minute) and returns the snapshot's
    /// name, `com.apple.TimeMachine.<date>.local`. Throws with tmutil's own words when it fails, and stops it after
    /// five minutes, so a hung tmutil cannot hold the batch forever.
    public static func create() async throws -> String {
        let output = try await run(URL(fileURLWithPath: "/usr/bin/tmutil"), ["localsnapshot"], timeout: 300)
        guard output.status == 0, let name = snapshotName(in: output.text) else {
            let words = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: words.isEmpty ? "tmutil stopped with status \(output.status)." : words,
            ])
        }
        return name
    }

    /// The snapshot `tmutil localsnapshot` reports, from a line like
    /// `Created local snapshot with date: 2026-09-23-152529`.
    static func snapshotName(in output: String) -> String? {
        let pattern = /Created local snapshot with date: (\d{4}-\d{2}-\d{2}-\d{6})/
        return output.firstMatch(of: pattern).map { "com.apple.TimeMachine.\($0.1).local" }
    }

    /// Waits on a termination handler, not `waitUntilExit`, so no cooperative thread blocks for the minute it takes.
    /// After `timeout` seconds the tool is stopped and this throws.
    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval) async throws -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let stopped = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                // tmutil writes a few lines, well inside the pipe's buffer, so reading after the exit cannot stall it.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard !stopped.withLock({ $0 }) else {
                    let words = "\(tool.lastPathComponent) did not finish in \(Int(timeout)) seconds, so it was stopped."
                    continuation.resume(throwing: CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: words]))
                    return
                }
                continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                stopped.withLock { $0 = true }
                process.terminate()
            }
        }
    }
}
