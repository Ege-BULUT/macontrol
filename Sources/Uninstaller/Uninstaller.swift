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
            // Any Info.plist can claim an identifier, `org.cups.printers` (the printer list) included, and only root
            // would remove what matched it. So unless Apple's signature vouched for the app, the user ticks those
            // themselves, and the note says why (T-0075 review 2, Risk 8).
            let unvouched = candidate.needsAdministrator && candidate.evidence.preselected && app.kind != .appleAppStore
            leftovers.append(Leftover(
                url: candidate.url, identity: FileIdentity(url: candidate.url), evidence: candidate.evidence,
                measurement: await measure(candidate.url), needsAdministrator: candidate.needsAdministrator,
                note: candidate.note ?? (unvouched ? Self.unvouchedNote(app.name) : nil), launchdLabel: candidate.launchdLabel
            ))
        }
        try Task.checkCancellation()
        return UninstallPlan(
            app: app,
            appMeasurement: await measure(app.url),
            leftovers: leftovers,
            blocker: Self.blocker(for: app, administrator: canUseAdministrator),
            bundleLaunchdLabels: found.bundleLaunchdLabels,
            notes: found.notes
        )
    }

    static func unvouchedNote(_ app: String) -> String {
        "Needs an administrator, and macontrol can't confirm it belongs to \(app). Check it before you remove it."
    }

    /// One app: `uninstall(jobs)` with one job, whose skip reason is thrown. The report carries the one batch.
    public func uninstall(
        _ plan: UninstallPlan, leftovers selected: Set<URL>, mode: DeletionMode = .trash, restorePoint: String? = nil
    ) async throws -> TrashReport {
        let result = await uninstall([UninstallJob(plan: plan, leftovers: selected)], mode: mode, restorePoint: restorePoint)
        if let error = result.skipped[plan.app.url] { throw error }
        return result.report
    }

    /// Several apps in one user action (DESIGN-debloat section 3.6). Per app: every item checked, the app quit and its
    /// launchd jobs booted out by exact label; an app that fails any step is skipped with its error, and the others go
    /// on (F-0030). Then ONE Safety batch, so at most one administrator dialog: each bundle followed by its chosen
    /// leftovers, every leftover with the bundle as `requiresGone`, so none is touched while its app is still there.
    /// Exactly what each plan listed is removed (F-0069): URLs not in the plan are ignored. `restorePoint` is the
    /// snapshot made before, recorded on the batch's journal lines.
    public func uninstall(_ jobs: [UninstallJob], mode: DeletionMode = .trash, restorePoint: String? = nil) async -> UninstallBatchReport {
        var items: [TrashItem] = []
        var skipped: [URL: UninstallError] = [:]
        for job in jobs {
            do {
                items += try await prepare(job)
            } catch let error as UninstallError {
                skipped[job.plan.app.url] = error
            } catch {
                skipped[job.plan.app.url] = .blocked(error.localizedDescription)
            }
        }
        let report = items.isEmpty ? TrashReport(batch: UUID(), outcomes: []) : await actions.remove(items, mode, restorePoint)
        return UninstallBatchReport(report: report, skipped: skipped)
    }

    /// The v1 steps for one app, up to the Trash: its bundle and chosen leftovers, in that order.
    private func prepare(_ job: UninstallJob) async throws -> [TrashItem] {
        try preflight(job)
        let plan = job.plan
        let chosen = plan.leftovers.filter { job.leftovers.contains($0.url) }
        let identifier = Self.vouchedIdentifier(plan.app)
        let bundle = TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity, bundleIdentifier: identifier)

        guard await actions.quit(plan.app) else { throw UninstallError.stillRunning(plan.app.name) }
        // A LaunchDaemon runs in the system domain: the helper boots it out, only after launchd confirms the plist.
        let userJobs = chosen.filter { !isSystemDaemon($0.url) }.compactMap(\.launchdLabel)
        var stopped = Set<String>()
        for label in plan.bundleLaunchdLabels + userJobs where stopped.insert(label).inserted {
            try await actions.bootout(label)
        }
        // Quitting first is politer than launchd's SIGTERM, but a KeepAlive job or login item can relaunch the app
        // before its bootout (why Homebrew runs launchctl before quit), so look again once nothing can restart it.
        if !stopped.isEmpty {
            guard await actions.quit(plan.app) else { throw UninstallError.stillRunning(plan.app.name) }
        }
        // Read again now: the app may have saved its settings while it quit.
        return [bundle] + chosen.map { leftover in
            var item = Self.itemToTrash(for: leftover)
            item.requiresGone = plan.app.url
            item.bundleIdentifier = identifier
            return item
        }
    }

    /// Every check `uninstall` makes before it quits the app, and nothing else. A caller with a step that can't be
    /// undone before the uninstall (Debloat deletes simulator runtimes for good) runs this first (T-0076 review, new
    /// cycle 1, 2).
    public func preflight(_ job: UninstallJob) throws {
        let plan = job.plan
        if let blocker = plan.blocker { throw UninstallError.blocked(blocker) }
        let chosen = plan.leftovers.filter { job.leftovers.contains($0.url) }
        if let stray = chosen.first(where: { !isInRemovableArea($0.url) }) {
            throw UninstallError.refused(stray.url, .protectedLocation("Outside the Library folders"))
        }
        if !canUseAdministrator, let administrative = chosen.first(where: \.needsAdministrator) {
            throw UninstallError.needsAdministrator(administrative.url)
        }
        let bundle = TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity, bundleIdentifier: Self.vouchedIdentifier(plan.app))
        try checkUnchanged([bundle] + chosen.map(Self.itemToTrash(for:)))
    }

    /// The helper's first-component rule lets `com.apple.dt.Xcode.plist` go only for the app it belongs to, so the
    /// identifier goes only where Apple's signature vouched for it (`.appleAppStore`): any bundle's Info.plist can
    /// claim `com.apple.loginwindow`. A third-party app has nothing Apple-named to claim (T-0075 review 1).
    private static func vouchedIdentifier(_ app: InstalledApp) -> String? {
        app.kind == .appleAppStore ? app.bundleIdentifier : nil
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

    /// With the administrator helper, a root-owned bundle is no blocker: it goes through the helper.
    static func blocker(for app: InstalledApp, administrator: Bool = false) -> String? {
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
        if !administrator && !FileSystem.isRemovableByUser(app.url) {
            return "Owned by the system, so removing it needs an administrator. Reveal it in Finder and drag it to the Trash."
        }
        return nil
    }

    /// Every leftover the finder can produce lies in a folder of a Library (`Library/Caches/<item>`), or is a package
    /// receipt (`/private/var/db/receipts/<id>.plist`). Checked on the standardized path, so a name carrying `..` cannot
    /// reach past it.
    private func isInRemovableArea(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !path.contains("\0") else { return false }
        func depth(below folder: URL) -> Int? {
            let base = folder.standardizedFileURL.path + "/"
            return path.hasPrefix(base) ? path.dropFirst(base.count).split(separator: "/").count : nil
        }
        let receipts = systemRoot.appendingPathComponent("private/var/db/receipts")
        return [home, systemRoot].contains { (depth(below: $0.appendingPathComponent("Library")) ?? 0) >= 2 }
            || depth(below: receipts) == 1
    }

    private func isSystemDaemon(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path
            == systemRoot.appendingPathComponent("Library/LaunchDaemons").standardizedFileURL.path
    }

    /// The last look before anything happens: each path still names what the plan saw, and Safety accepts it.
    /// An item with no recorded identity has nothing to compare, so it counts as changed.
    private func checkUnchanged(_ items: [TrashItem]) throws {
        for item in items {
            guard let expected = item.expectedIdentity, FileIdentity(url: item.url) == expected else {
                throw UninstallError.changedSincePlan(item.url)
            }
            // Root-owned is fine when the helper can take it: Safety routes it there.
            if let reason = ProtectedPaths.refusal(for: item.url, home: home), !(reason == .needsAdministrator && canUseAdministrator) {
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
