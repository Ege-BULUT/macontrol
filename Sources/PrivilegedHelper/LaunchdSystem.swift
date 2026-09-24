import Foundation

/// `/bin/launchctl` for the helper's LaunchDaemon step (DESIGN-debloat section 3.5 step 4): an argument array, no
/// shell and an empty environment. This file is the helper's only place allowed to start a process
/// (SafetyTests/SinkAuditTests).
enum LaunchdSystem {
    /// launchctl's exit status and standard output; -1 when it could not start.
    @Sendable static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.environment = [:]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
