import Foundation
import MacontrolCore
import Safety
import ScanEngine

/// Lists apps, finds their leftovers by evidence, and removes both in a safe order (docs/ARCHITECTURE.md section 7).
public final class Uninstaller: Sendable {
    public let home: URL
    public let applicationFolders: [URL]
    /// `/` in the app. Tests point it at a temporary folder that stands in for /Library, /System and the receipts.
    public let systemRoot: URL
    private let engine: ScanEngine
    private let actions: UninstallActions

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationFolders: [URL]? = nil,
        systemRoot: URL = URL(fileURLWithPath: "/"),
        engine: ScanEngine = ScanEngine(),
        trash: TrashService,
        actions: UninstallActions? = nil
    ) {
        self.home = home
        self.systemRoot = systemRoot
        self.applicationFolders = applicationFolders ?? [
            systemRoot.appendingPathComponent("Applications"),
            home.appendingPathComponent("Applications"),
            systemRoot.appendingPathComponent("System/Applications"),
        ]
        self.engine = engine
        self.actions = actions ?? .live(trash: trash)
    }

    /// Apps in each application folder and one level of subfolders (`Utilities`, vendor folders). Sizes come with the plan.
    public func installedApps() async throws -> [InstalledApp] {
        let folders = applicationFolders
        let systemRoot = systemRoot
        return await offCooperativePool {
            folders.flatMap(Self.appURLs(in:)).map { AppBundle(url: $0).installedApp(systemRoot: systemRoot) }
        }
    }

    public func plan(for app: InstalledApp) async throws -> UninstallPlan {
        let others = try await installedApps().filter { $0.url.path != app.url.path }
        let finder = LeftoverFinder(app: app, others: others, home: home, systemRoot: systemRoot)
        // A built-in app never goes, so its data is not a leftover: Safari's history is not junk, and the groups
        // it shares with other Apple apps would otherwise look like its own.
        let found = app.kind == .builtIn
            ? LeftoverFinder.Result(candidates: [], bundleLaunchdLabels: [], notes: [])
            : await offCooperativePool { finder.run() }
        var leftovers: [Leftover] = []
        for candidate in found.candidates {
            leftovers.append(Leftover(
                url: candidate.url, identity: FileIdentity(url: candidate.url), evidence: candidate.evidence,
                measurement: await measure(candidate.url), needsAdministrator: candidate.needsAdministrator,
                note: candidate.note, launchdLabel: candidate.launchdLabel
            ))
        }
        return UninstallPlan(
            app: app,
            appMeasurement: await measure(app.url),
            leftovers: leftovers,
            blocker: Self.blocker(for: app),
            bundleLaunchdLabels: found.bundleLaunchdLabels,
            notes: found.notes
        )
    }

    /// Checks every item, quits the app, boots out its launchd jobs by exact label, then trashes the bundle and the
    /// chosen leftovers in one batch, so one Undo restores it all. Any failed step stops before the next one (F-0030),
    /// and exactly what the plan listed is trashed (F-0069): URLs not in the plan are ignored.
    public func uninstall(_ plan: UninstallPlan, leftovers selected: Set<URL>) async throws -> TrashReport {
        if let blocker = plan.blocker { throw UninstallError.blocked(blocker) }
        let chosen = plan.leftovers.filter { selected.contains($0.url) }
        if let administrative = chosen.first(where: \.needsAdministrator) {
            throw UninstallError.needsAdministrator(administrative.url)
        }
        let items = [TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity)]
            + chosen.map { TrashItem(url: $0.url, expectedIdentity: $0.identity) }
        try checkUnchanged(items)

        guard await actions.quit(plan.app) else { throw UninstallError.stillRunning(plan.app.name) }
        var stopped = Set<String>()
        for label in plan.bundleLaunchdLabels + chosen.compactMap(\.launchdLabel) where stopped.insert(label).inserted {
            try await actions.bootout(label)
        }
        return await actions.moveToTrash(items)
    }

    // MARK: Helpers

    static func appURLs(in folder: URL) -> [URL] {
        FileSystem.children(of: folder).sorted().flatMap { name -> [URL] in
            let url = folder.appendingPathComponent(name)
            if name.hasSuffix(".app") { return isListable(url) ? [url] : [] }
            guard FileSystem.isDirectory(url) else { return [] }
            return FileSystem.children(of: url).sorted()
                .filter { $0.hasSuffix(".app") }
                .map { url.appendingPathComponent($0) }
                .filter(isListable)
        }
    }

    /// A real bundle, or a SIP-restricted link to one (Safari lives in a cryptex behind `/Applications/Safari.app`).
    /// Other links are skipped: trashing a link would leave the app it points to in place.
    private static func isListable(_ url: URL) -> Bool {
        guard let info = FileSystem.status(of: url) else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return true
        case S_IFLNK: return info.st_flags & UInt32(SF_RESTRICTED) != 0
        default: return false
        }
    }

    static func blocker(for app: InstalledApp) -> String? {
        if app.kind == .builtIn {
            return "Part of macOS. It lives on the sealed system volume and can't be removed."
        }
        if app.url.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path {
            return "macontrol can't remove itself while it's running."
        }
        if !FileSystem.isRemovableByUser(app.url) {
            return "Owned by the system, so removing it needs an administrator. Reveal it in Finder and drag it to the Trash."
        }
        return nil
    }

    /// The last look before anything happens: each path still names what the plan saw, and Safety accepts it.
    private func checkUnchanged(_ items: [TrashItem]) throws {
        for item in items {
            guard let now = FileIdentity(url: item.url), item.expectedIdentity == nil || item.expectedIdentity == now else {
                throw UninstallError.changedSincePlan(item.url)
            }
            if let reason = ProtectedPaths.refusal(for: item.url, home: home) {
                throw UninstallError.refused(item.url, reason)
            }
        }
    }

    /// A size that could not be read is shown as incomplete, never as a reason to drop the item.
    private func measure(_ url: URL) async -> ItemMeasurement {
        (try? await engine.measure(url))
            ?? ItemMeasurement(allocated: 0, logical: 0, fileCount: 0, newestModification: nil, isIncomplete: true)
    }
}
