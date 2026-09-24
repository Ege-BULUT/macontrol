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
    private let administrator: PrivilegedLauncher?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationFolders: [URL]? = nil,
        systemRoot: URL = URL(fileURLWithPath: "/"),
        engine: ScanEngine = ScanEngine(),
        trash: TrashService,
        actions: UninstallActions? = nil,
        administrator: PrivilegedLauncher? = nil
    ) {
        self.home = home
        self.systemRoot = systemRoot
        self.applicationFolders = applicationFolders ?? [
            systemRoot.appendingPathComponent("Applications"),
            home.appendingPathComponent("Applications"),
            systemRoot.appendingPathComponent("System/Applications"),
        ]
        self.engine = engine
        self.actions = actions ?? .live(trash: trash, administrator: administrator)
        self.administrator = administrator
    }

    /// True when root-owned items can go through the administrator helper.
    public var canUseAdministrator: Bool { administrator != nil }

    /// Apps in each application folder and one level of subfolders (`Utilities`, vendor folders). Sizes come with the plan.
    public func installedApps() async throws -> [InstalledApp] {
        let folders = applicationFolders
        let systemRoot = systemRoot
        return await offCooperativePool {
            folders.flatMap(Self.appURLs(in:)).map { AppBundle(url: $0).installedApp(systemRoot: systemRoot) }
        }
    }

    public func plan(for app: InstalledApp) async throws -> UninstallPlan {
        // The UI plans the selected app in a task it cancels on the next selection; the walks below never see that.
        let others = try await installedApps().filter { $0.url.path != app.url.path }
        try Task.checkCancellation()
        let finder = LeftoverFinder(app: app, others: others, home: home, systemRoot: systemRoot)
        // A built-in app never goes, so its data is not a leftover: Safari's history is not junk, and the groups
        // it shares with other Apple apps would otherwise look like its own.
        let found = app.kind == .builtIn
            ? LeftoverFinder.Result(candidates: [], bundleLaunchdLabels: [], notes: [])
            : await offCooperativePool { finder.run() }
        var leftovers: [Leftover] = []
        for candidate in found.candidates {
            try Task.checkCancellation()
            leftovers.append(Leftover(
                url: candidate.url, identity: FileIdentity(url: candidate.url), evidence: candidate.evidence,
                measurement: await measure(candidate.url), needsAdministrator: candidate.needsAdministrator,
                note: candidate.note, launchdLabel: candidate.launchdLabel
            ))
        }
        try Task.checkCancellation()
        return UninstallPlan(
            app: app,
            appMeasurement: await measure(app.url),
            leftovers: leftovers,
            blocker: Self.blocker(for: app),
            bundleLaunchdLabels: found.bundleLaunchdLabels,
            notes: found.notes
        )
    }

    /// Checks every item, quits the app and boots out its launchd jobs by exact label. Then the bundle goes to the
    /// Trash on its own, and the chosen leftovers follow only once it is there: Safety carries on past a refused item,
    /// so one shared batch would take the data of an app that stays installed. Any failed step stops before the next
    /// one (F-0030), and exactly what the plan listed is trashed (F-0069): URLs not in the plan are ignored.
    /// The report carries the bundle's batch; the leftovers are a second batch in History.
    public func uninstall(_ plan: UninstallPlan, leftovers selected: Set<URL>, mode: DeletionMode = .trash) async throws -> TrashReport {
        if let blocker = plan.blocker { throw UninstallError.blocked(blocker) }
        let chosen = plan.leftovers.filter { selected.contains($0.url) }
        if let stray = chosen.first(where: { !isInsideLibraryFolder($0.url) }) {
            throw UninstallError.refused(stray.url, .protectedLocation("Outside the Library folders"))
        }
        if let administrative = chosen.first(where: \.needsAdministrator) {
            throw UninstallError.needsAdministrator(administrative.url)
        }
        let bundle = TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity)
        try checkUnchanged([bundle] + chosen.map(Self.itemToTrash(for:)))

        guard await actions.quit(plan.app) else { throw UninstallError.stillRunning(plan.app.name) }
        var stopped = Set<String>()
        for label in plan.bundleLaunchdLabels + chosen.compactMap(\.launchdLabel) where stopped.insert(label).inserted {
            try await actions.bootout(label)
        }
        // Quitting first is politer than launchd's SIGTERM, but a KeepAlive job or login item can relaunch the app
        // before its bootout (why Homebrew runs launchctl before quit), so look again once nothing can restart it.
        if !stopped.isEmpty {
            guard await actions.quit(plan.app) else { throw UninstallError.stillRunning(plan.app.name) }
        }
        let appReport = await actions.remove([bundle], mode)
        // An updater still finishing after the quit can put a new copy at the path the Trash step just emptied.
        let bundleGone = switch appReport.outcomes.first { case .trashed?, .deleted?: true; default: false }
        guard bundleGone, !FileSystem.exists(plan.app.url) else {
            let reason = "Not moved, because \(plan.app.name) is still installed."
            let kept = chosen.map { TrashOutcome.failed($0.url, message: reason) }
            return TrashReport(batch: appReport.batch, outcomes: appReport.outcomes + kept)
        }
        if chosen.isEmpty { return appReport }
        // Read again now: the app may have saved its settings while it quit.
        let leftoverReport = await actions.remove(chosen.map(Self.itemToTrash(for:)), mode)
        return TrashReport(batch: appReport.batch, outcomes: appReport.outcomes + leftoverReport.outcomes)
    }

    /// Several apps in one user action (DESIGN-debloat section 3.6): an app that fails its checks, quit or bootout
    /// is skipped with its error, and the others go on.
    /// Stub (T-0072): each job runs through the single-app uninstall in turn; the report carries the first batch.
    /// privileged-helper replaces it with one `remove` call ordered by `requiresGone`.
    public func uninstall(_ jobs: [UninstallJob], mode: DeletionMode = .trash) async -> UninstallBatchReport {
        var batch: UUID?
        var outcomes: [TrashOutcome] = []
        var skipped: [URL: UninstallError] = [:]
        for job in jobs {
            do {
                let report = try await uninstall(job.plan, leftovers: job.leftovers, mode: mode)
                batch = batch ?? report.batch
                outcomes += report.outcomes
            } catch let error as UninstallError {
                skipped[job.plan.app.url] = error
            } catch {
                skipped[job.plan.app.url] = .blocked(error.localizedDescription)
            }
        }
        return UninstallBatchReport(report: TrashReport(batch: batch ?? UUID(), outcomes: outcomes), skipped: skipped)
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
        // The Locked flag also makes the bundle unwritable, which would otherwise read as root-owned.
        if let flags = FileSystem.status(of: app.url)?.st_flags, flags & UInt32(UF_IMMUTABLE) != 0 {
            return "Locked in Finder. Clear Locked in its Get Info window, then try again."
        }
        if !FileSystem.isRemovableByUser(app.url) {
            return "Owned by the system, so removing it needs an administrator. Reveal it in Finder and drag it to the Trash."
        }
        return nil
    }

    /// Every leftover the finder can produce lies in a folder of a Library (`Library/Caches/<item>`). Checked on the
    /// standardized path, so a name carrying `..` cannot reach past it.
    private func isInsideLibraryFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return !path.contains("\0") && [home, systemRoot].contains { base in
            let library = base.appendingPathComponent("Library").standardizedFileURL.path + "/"
            return path.hasPrefix(library) && path.dropFirst(library.count).split(separator: "/").count >= 2
        }
    }

    /// The last look before anything happens: each path still names what the plan saw, and Safety accepts it.
    /// An item with no recorded identity has nothing to compare, so it counts as changed.
    private func checkUnchanged(_ items: [TrashItem]) throws {
        for item in items {
            guard let expected = item.expectedIdentity, FileIdentity(url: item.url) == expected else {
                throw UninstallError.changedSincePlan(item.url)
            }
            if let reason = ProtectedPaths.refusal(for: item.url, home: home) {
                throw UninstallError.refused(item.url, reason)
            }
        }
    }

    /// cfprefsd replaces a preferences plist on every write, and apps save their settings as they quit, so a regular
    /// file's plan-time identity goes stale with no change of owner. A regular file still at the planned path is taken
    /// as it is now. Folders and links keep the identity the plan saw, and an item the plan had none for gets none.
    private static func itemToTrash(for leftover: Leftover) -> TrashItem {
        var identity = leftover.identity
        if identity != nil, let info = FileSystem.status(of: leftover.url), info.st_mode & S_IFMT == S_IFREG {
            identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
        }
        return TrashItem(url: leftover.url, expectedIdentity: identity)
    }

    /// A size that could not be read is shown as incomplete, never as a reason to drop the item.
    private func measure(_ url: URL) async -> ItemMeasurement {
        (try? await engine.measure(url))
            ?? ItemMeasurement(allocated: 0, logical: 0, fileCount: 0, newestModification: nil, isIncomplete: true)
    }
}
