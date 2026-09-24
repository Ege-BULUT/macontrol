import Foundation

/// A simulator runtime (iOS 26.5, watchOS 26.5…) as CoreSimulator lists it. Runtimes live in SIP-restricted
/// `/System/Library/AssetsV2`, so only CoreSimulator's own tool can delete them, and they never go to the Trash.
public struct SimRuntime: Sendable, Hashable, Identifiable {
    /// The disk image's UUID, the only form `delete` is ever given (never `all` or an option).
    public var id: String
    /// "iOS 26.5".
    public var name: String
    public var bytes: UInt64

    public init(id: String, name: String, bytes: UInt64) {
        self.id = id
        self.name = name
        self.bytes = bytes
    }
}

public enum SimRuntimeError: Error, Hashable {
    /// The tool could not start, or ended with this status.
    case failed(Int32)
    /// Its output was not the JSON it documents.
    case unreadable
}

/// Lists and deletes runtimes with CoreSimulator's `simctl` binary at its fixed path (DESIGN-debloat section 4.4).
/// Never `xcrun`, which follows `xcode-select`, and never Xcode's `usr/bin/simctl`: that is a bash script that may
/// run `xcodebuild -runFirstLaunch` and reinstall the framework being removed. The environment is what that
/// script sets: `DEVELOPER_DIR` of the Xcode being removed. Runs as the user; tests inject the runner.
public struct SimRuntimeTool: Sendable {
    public static let simctl = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl")

    /// Runs `tool` with an argument array and exactly `environment`; returns its exit status and standard output.
    public typealias Runner = @Sendable (_ tool: URL, _ arguments: [String], _ environment: [String: String]) async -> (status: Int32, output: Data)

    public var run: Runner

    public init(run: @escaping Runner) {
        self.run = run
    }

    public func list(xcode: URL) async throws -> [SimRuntime] {
        let result = await run(Self.simctl, ["runtime", "list", "-j"], Self.environment(xcode: xcode))
        guard result.status == 0 else { throw SimRuntimeError.failed(result.status) }
        return try Self.parse(result.output)
    }

    public func delete(_ runtime: SimRuntime, xcode: URL) async throws {
        guard UUID(uuidString: runtime.id) != nil else { throw SimRuntimeError.unreadable }
        let result = await run(Self.simctl, ["runtime", "delete", runtime.id], Self.environment(xcode: xcode))
        guard result.status == 0 else { throw SimRuntimeError.failed(result.status) }
    }

    /// The deletable runtimes in `simctl runtime list -j`, largest first. An entry whose identifier is not a UUID is
    /// dropped, so nothing but a UUID reaches `delete`.
    static func parse(_ output: Data) throws -> [SimRuntime] {
        guard let images = try? JSONSerialization.jsonObject(with: output) as? [String: [String: Any]] else {
            throw SimRuntimeError.unreadable
        }
        return images.values.compactMap { image -> SimRuntime? in
            guard image["deletable"] as? Bool == true, let id = image["identifier"] as? String, UUID(uuidString: id) != nil,
                  let bytes = (image["sizeBytes"] as? NSNumber)?.uint64Value else { return nil }
            // com.apple.CoreSimulator.SimRuntime.iOS-26-5 → iOS
            let runtime = (image["runtimeIdentifier"] as? String)?.split(separator: ".").last?.split(separator: "-").first
            let name = [runtime.map(String.init), image["version"] as? String].compactMap { $0 }.joined(separator: " ")
            return SimRuntime(id: id, name: name.isEmpty ? "Simulator runtime" : name, bytes: bytes)
        }
        .sorted { ($0.bytes, $0.id) > ($1.bytes, $1.id) }
    }

    /// A short allowlist of the app's (already scrubbed) environment, plus the Xcode being removed.
    static func environment(xcode: URL, from current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = current.filter { ["HOME", "USER", "LOGNAME", "TMPDIR"].contains($0.key) }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["DEVELOPER_DIR"] = xcode.appendingPathComponent("Contents/Developer").path
        return environment
    }

    /// The real tool. Its output is read on a GCD thread, never the cooperative pool.
    public static let live = SimRuntimeTool { tool, arguments, environment in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                process.environment = environment
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, Data()))
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, data))
            }
        }
    }
}
