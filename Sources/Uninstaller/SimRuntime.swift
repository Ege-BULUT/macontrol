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
    /// The plan's note on the profile item that holds this tool. Every screen that shows the plan holds the item back
    /// with it, since only Debloat deletes the runtimes first; Debloat replaces it (review 2, 1).
    public static let heldNote = "Holds the only tool that deletes simulator runtimes. To delete them too, remove Xcode in Debloat."

    /// Runs `tool` with an argument array and exactly `environment`; returns its exit status and standard output.
    public typealias Runner = @Sendable (_ tool: URL, _ arguments: [String], _ environment: [String: String]) async -> (status: Int32, output: Data)

    public var run: Runner
    /// Asks Xcode, and the apps inside it (Simulator), to quit before its runtimes go: `simctl runtime delete` shuts
    /// down running simulators. True when none is left. Tests keep the default, which quits nothing.
    public var quit: @Sendable (InstalledApp) async -> Bool
    /// Whether CoreSimulator's tool is there. An Xcode that was never opened has none: then it has no runtimes, and
    /// removing it takes no tool away.
    public var isInstalled: @Sendable () -> Bool
    /// How long `waitUntilGone` waits, and how often it lists. Tests shorten both.
    public var gonePolling: (limit: Duration, every: Duration) = (.seconds(60), .seconds(1))

    public init(
        run: @escaping Runner, quit: @escaping @Sendable (InstalledApp) async -> Bool = { _ in true },
        isInstalled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.run = run
        self.quit = quit
        self.isInstalled = isInstalled
    }

    public func list(xcode: URL) async throws -> [SimRuntime] {
        guard isInstalled() else { return [] }
        let result = await run(Self.simctl, ["runtime", "list", "-j"], Self.environment(xcode: xcode))
        guard result.status == 0 else { throw SimRuntimeError.failed(result.status) }
        return try Self.parse(result.output)
    }

    public func delete(_ runtime: SimRuntime, xcode: URL) async throws {
        guard UUID(uuidString: runtime.id) != nil else { throw SimRuntimeError.unreadable }
        let result = await run(Self.simctl, ["runtime", "delete", runtime.id], Self.environment(xcode: xcode))
        guard result.status == 0 else { throw SimRuntimeError.failed(result.status) }
    }

    /// `runtime delete` exits 0 once CoreSimulator has queued the delete, not once it is done. On this Mac the runtime
    /// was still listed as Ready 3 s later, and simdiskimaged, which runs from the CoreSimulator.framework a Debloat run
    /// removes next, purged it 4.9 s after the tool exited (T-0076 review, new cycle 1, 1). True once no entry of the
    /// list, deletable or not, has one of `ids`; false when one still does at the limit, or the list can't be read.
    public func waitUntilGone(_ ids: Set<String>, xcode: URL) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + gonePolling.limit
        while true {
            let result = await run(Self.simctl, ["runtime", "list", "-j"], Self.environment(xcode: xcode))
            if result.status == 0, let images = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] {
                let listed = Set(images.keys).union(images.values.compactMap { ($0 as? [String: Any])?["identifier"] as? String })
                if listed.isDisjoint(with: ids) { return true }
            }
            guard clock.now < deadline else { return false }
            do { try await Task.sleep(until: min(clock.now + gonePolling.every, deadline), clock: clock) } catch { return false }
        }
    }

    /// The deletable runtimes in `simctl runtime list -j`, largest first. An entry that doesn't say whether it is
    /// deletable, or a deletable one without a UUID identifier and a size, fails the whole list: a runtime skipped
    /// here would stay for good once Xcode goes (review 2, 2). Nothing but a UUID reaches `delete`.
    static func parse(_ output: Data) throws -> [SimRuntime] {
        guard let images = try? JSONSerialization.jsonObject(with: output) as? [String: [String: Any]] else {
            throw SimRuntimeError.unreadable
        }
        return try images.values.compactMap { image -> SimRuntime? in
            guard let deletable = image["deletable"] as? Bool else { throw SimRuntimeError.unreadable }
            guard deletable else { return nil }
            guard let id = image["identifier"] as? String, UUID(uuidString: id) != nil,
                  let bytes = (image["sizeBytes"] as? NSNumber)?.uint64Value else { throw SimRuntimeError.unreadable }
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

    /// The real tool, Xcode's polite quit and the tool's fixed path.
    public static let live = SimRuntimeTool(
        run: runner(timeout: .seconds(120)),
        quit: { await RunningApps.quit($0) },
        isInstalled: { FileManager.default.isExecutableFile(atPath: simctl.path) }
    )

    /// Runs the tool with its output read on a GCD thread, never the cooperative pool. A tool still running after
    /// `timeout` (a hung CoreSimulatorService) is terminated, which counts as a failure: Xcode is then kept.
    // ponytail: one limit for list and delete; split it once T-0078 measures how long a real delete takes.
    static func runner(timeout: Duration) -> Runner {
        { tool, arguments, environment in
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
                    let started = ContinuousClock.now
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: (-1, Data()))
                        return
                    }
                    let limit = DispatchWorkItem { process.terminate() }
                    let (seconds, attoseconds) = timeout.components
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18, execute: limit)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    limit.cancel()
                    // Whatever a stopped tool says at the end, it did not finish.
                    let finished = ContinuousClock.now - started < timeout
                    continuation.resume(returning: (finished ? process.terminationStatus : -1, data))
                }
            }
        }
    }
}
