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
    /// One Safety batch in the given mode (`TrashService.remove`).
    public var remove: @Sendable ([TrashItem], DeletionMode) async -> TrashReport

    public init(
        quit: @escaping @Sendable (InstalledApp) async -> Bool,
        bootout: @escaping @Sendable (_ label: String) async throws -> Void,
        remove: @escaping @Sendable ([TrashItem], DeletionMode) async -> TrashReport
    ) {
        self.quit = quit
        self.bootout = bootout
        self.remove = remove
    }

    public static func live(
        trash: TrashService, launchctl: LaunchctlRunner = .system, administrator: PrivilegedLauncher? = nil
    ) -> UninstallActions {
        UninstallActions(
            quit: { await RunningApps.quit($0) },
            bootout: { try await Launchd.bootout(label: $0, runner: launchctl) },
            remove: { await trash.remove($0, mode: $1, administrator: administrator) }
        )
    }
}

@MainActor
enum RunningApps {
    /// Polite quit only: `terminate()` lets the app save and ask the user. No force quit, no pattern kill.
    static func quit(_ app: InstalledApp, timeout: Duration = .seconds(10)) async -> Bool {
        let running = NSWorkspace.shared.runningApplications.filter {
            isInstance(of: app, bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
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

    /// This bundle or a helper inside it. Another copy with the same identifier keeps running, except a translocated
    /// one: Gatekeeper runs a quarantined app from a random read-only path, so that process may be this copy.
    nonisolated static func isInstance(of app: InstalledApp, bundleURL: URL?, bundleIdentifier: String?) -> Bool {
        let bundlePath = app.url.standardizedFileURL.path
        let path = bundleURL?.standardizedFileURL.path ?? ""
        return path == bundlePath || path.hasPrefix(bundlePath + "/")
            || (path.contains("/AppTranslocation/") && app.bundleIdentifier != nil && bundleIdentifier == app.bundleIdentifier)
    }
}
