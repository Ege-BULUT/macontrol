import Darwin
import Foundation

/// Runs `/bin/launchctl` with an argument array, never through a shell, and returns its exit status.
/// This file is the only place in macontrol allowed to launch a process (SafetyTests/SinkAuditTests).
/// Tests inject their own runner, so they never talk to launchd.
public struct LaunchctlRunner: Sendable {
    public var run: @Sendable (_ arguments: [String]) async throws -> Int32

    public init(run: @escaping @Sendable (_ arguments: [String]) async throws -> Int32) {
        self.run = run
    }

    public static let system = LaunchctlRunner { arguments in
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum Launchd {
    /// launchctl's status when no such service is loaded (ESRCH): there is nothing to stop.
    static let notLoaded: Int32 = 3

    /// Stops the user's job with exactly this label. No wildcard, no pattern, no kill (F-0023, F-0067).
    static func bootout(label: String, runner: LaunchctlRunner, uid: uid_t = getuid()) async throws {
        guard !label.isEmpty, !label.contains("/") else {
            throw UninstallError.bootoutFailed(label: label, status: -1)
        }
        let status = try await runner.run(["bootout", "gui/\(uid)/\(label)"])
        guard status == 0 || status == notLoaded else {
            throw UninstallError.bootoutFailed(label: label, status: status)
        }
    }
}
