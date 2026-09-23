import AppKit
import Foundation
import Safety

/// Everything an uninstall does to the running system. Tests pass their own, so they never quit a real app,
/// call launchctl or trash a file.
public struct UninstallActions: Sendable {
    /// Asks every running copy of the app, and any helper app inside its bundle, to quit. True when none is left.
    public var quit: @Sendable (InstalledApp) async -> Bool
    /// Stops one user launchd job by its exact label; throws when it may still be running.
    public var bootout: @Sendable (_ label: String) async throws -> Void
    public var moveToTrash: @Sendable ([TrashItem]) async -> TrashReport

    public init(
        quit: @escaping @Sendable (InstalledApp) async -> Bool,
        bootout: @escaping @Sendable (_ label: String) async throws -> Void,
        moveToTrash: @escaping @Sendable ([TrashItem]) async -> TrashReport
    ) {
        self.quit = quit
        self.bootout = bootout
        self.moveToTrash = moveToTrash
    }

    public static func live(trash: TrashService, launchctl: LaunchctlRunner = .system) -> UninstallActions {
        UninstallActions(
            quit: { await RunningApps.quit($0) },
            bootout: { try await Launchd.bootout(label: $0, runner: launchctl) },
            moveToTrash: { await trash.moveToTrash($0) }
        )
    }
}

@MainActor
enum RunningApps {
    /// Polite quit only: `terminate()` lets the app save and ask the user. No force quit, no pattern kill.
    static func quit(_ app: InstalledApp, timeout: Duration = .seconds(10)) async -> Bool {
        let bundlePath = app.url.standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.filter { process in
            let path = process.bundleURL?.standardizedFileURL.path ?? ""
            return path == bundlePath || path.hasPrefix(bundlePath + "/")
                || (app.bundleIdentifier != nil && process.bundleIdentifier == app.bundleIdentifier)
        }
        running.forEach { $0.terminate() }
        let deadline = ContinuousClock.now + timeout
        // `isTerminated` is updated by the main run loop, which keeps turning while this task sleeps.
        while running.contains(where: { !$0.isTerminated }) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }
}
