import Darwin
import Foundation
import MacontrolCore
import Observation
import Safety
import ScanEngine
import Uninstaller

/// One app row of the checklist: the app, its plan once found, and the simulator runtimes it deletes first.
struct DebloatApp: Identifiable {
    let app: InstalledApp
    var plan: UninstallPlan?
    var runtimes: [SimRuntime] = []
    var id: URL { app.url }

    var runtimeBytes: UInt64 { runtimes.reduce(0) { $0 + $1.bytes } }
    /// The bundle, everything the plan found and the runtimes.
    var total: UInt64 {
        guard let plan else { return 0 }
        return plan.leftovers.reduce(plan.appMeasurement.allocated + runtimeBytes) { $0 + $1.measurement.allocated }
    }
}

/// The open confirmation, fixed when it opens: its mode, jobs and runtimes do not follow later changes.
struct DebloatConfirmation: Identifiable {
    let id = UUID()
    let mode: DeletionMode
    /// Every ticked app with its chosen leftovers, in list order.
    let jobs: [UninstallJob]
    /// Runtimes deleted first, per Xcode bundle.
    let runtimes: [(xcode: InstalledApp, runtimes: [SimRuntime])]
    let rows: [TrashSheetRow]
    let notes: [String]
    /// `xcode-select` points into a bundle being removed.
    let breaksDeveloperTools: Bool
    var isWorking = false
    var report: TrashReport?
    var notMoved: [URL: String] = [:]
    var message: String?

    var runtimeBytes: UInt64 { runtimes.flatMap(\.runtimes).reduce(0) { $0 + $1.bytes } }
    var rowBytes: UInt64 { rows.reduce(0) { $0 + $1.bytes } }
}

/// A checkbox the user set, with the note its row showed then: a row that gained or lost a note since goes back to
/// its default (F-0011, F-0022).
private struct Choice {
    let chosen: Bool
    let note: String?
}

/// Apple's removable apps as a checklist, removed in one run (DESIGN-debloat section 4).
@Observable
public final class DebloatModel {
    static let developerToolsNote = "git, clang and other developer tools stop working until you run sudo xcode-select --reset in Terminal."
    static let resetCommand = "sudo xcode-select --reset"
    static let runtimeNote = "Download them again in Xcode > Settings > Components."

    /// Apple's App Store apps (Xcode, GarageBand, iWork…).
    var apps: [DebloatApp] = []
    /// `Install macOS …` bundles.
    var installers: [DebloatApp] = []
    /// Part of macOS: shown locked, with their size.
    var locked: [InstalledApp] = []
    var lockedSizes: [URL: UInt64] = [:]
    var hasLoadedApps = false
    private(set) var loadError: String?
    /// App rows the user ticked. Empty at first, always (section 4.5): Xcode is a tool someone chose, not bloat.
    var ticked: Set<URL> = []
    var expanded: Set<URL> = []
    /// The Part of macOS row whose panel is open.
    var lockedPanel: InstalledApp?
    var confirmation: DebloatConfirmation?

    let hardcore: HardcoreMode
    /// Root-owned items can go through the administrator helper; without it they stay unselectable (v1).
    let canUseAdministrator: Bool
    private let uninstaller: Uninstaller?
    private let engine: ScanEngine?
    private let runtimeTool: SimRuntimeTool
    private let profiles: AppleProfiles
    /// Where `xcode-select` points: `readlink /private/var/db/xcode_select_link`.
    private let developerDirectory: () -> String?
    private let uninstallJobs: ([UninstallJob], DeletionMode) async -> UninstallBatchReport
    /// Every installed app, for "another Xcode is installed".
    var allApps: [InstalledApp] = []
    private var choices: [URL: [URL: Choice]] = [:]
    private var runtimeChoices: [URL: Choice] = [:]

    public convenience init(uninstaller: Uninstaller?, hardcore: HardcoreMode = HardcoreMode()) {
        self.init(uninstaller: uninstaller, hardcore: hardcore, engine: ScanEngine())
    }

    init(
        uninstaller: Uninstaller?,
        hardcore: HardcoreMode = HardcoreMode(),
        engine: ScanEngine?,
        runtimeTool: SimRuntimeTool = .live,
        profiles: AppleProfiles = .bundled,
        developerDirectory: @escaping () -> String? = DebloatModel.xcodeSelectLink,
        uninstallJobs: (([UninstallJob], DeletionMode) async -> UninstallBatchReport)? = nil,
        canUseAdministrator: Bool? = nil
    ) {
        self.uninstaller = uninstaller
        self.hardcore = hardcore
        self.engine = engine
        self.runtimeTool = runtimeTool
        self.profiles = profiles
        self.developerDirectory = developerDirectory
        self.canUseAdministrator = canUseAdministrator ?? uninstaller?.canUseAdministrator ?? false
        self.uninstallJobs = uninstallJobs ?? { jobs, mode in
            guard let uninstaller else {
                // Demo data: nothing real to remove.
                let urls = jobs.flatMap { [$0.plan.app.url] + $0.leftovers.sorted { $0.path < $1.path } }
                return UninstallBatchReport(report: TrashReport(batch: UUID(), outcomes: urls.map { .refused($0, .notImplemented) }), skipped: [:])
            }
            return await uninstaller.uninstall(jobs, mode: mode)
        }
    }

    // MARK: Loading

    /// Lists the apps once, then finds every plan still missing. Plans walk whole bundles (Xcode is 26 GB), so a
    /// visit does not redo them; Scan Again does.
    func load() async {
        guard let uninstaller else { return }
        if !hasLoadedApps {
            do {
                let found = try await uninstaller.installedApps()
                loadError = nil
                present(found)
            } catch {
                loadError = error.localizedDescription
                hasLoadedApps = true
                return
            }
        }
        await findPlans()
    }

    func rescan() async {
        hasLoadedApps = false
        apps = []
        installers = []
        await load()
    }

    /// Sorts the installed apps into the three sections. Ticks survive only for apps still listed.
    func present(_ found: [InstalledApp]) {
        allApps = found
        let sorted = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let previous = Dictionary((apps + installers).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let row = { (app: InstalledApp) in previous[app.url].flatMap { $0.app.identity == app.identity ? $0 : nil } ?? DebloatApp(app: app) }
        let installerURLs = Set(sorted.filter(\.isMacOSInstaller).map(\.url))
        apps = sorted.filter { $0.kind == .appleAppStore && !installerURLs.contains($0.url) }.map(row)
        installers = sorted.filter { installerURLs.contains($0.url) }.map(row)
        locked = sorted.filter { $0.kind == .builtIn }
        ticked.formIntersection((apps + installers).map(\.id))
        hasLoadedApps = true
    }

    private func findPlans() async {
        guard let uninstaller else { return }
        for app in (apps + installers).filter({ $0.plan == nil }).map(\.app) {
            guard !Task.isCancelled else { return }
            guard let plan = try? await uninstaller.plan(for: app) else { continue }
            let runtimes = profiles.profile(for: app.bundleIdentifier)?.simulatorRuntimes == true
                ? (try? await runtimeTool.list(xcode: app.url)) ?? [] : []
            update(app.url) { $0.plan = plan; $0.runtimes = runtimes }
        }
        guard let engine else { return }
        for app in locked where lockedSizes[app.url] == nil {
            guard !Task.isCancelled else { return }
            if let size = try? await engine.measure(app.url) { lockedSizes[app.url] = size.allocated }
        }
    }

    private func update(_ url: URL, _ change: (inout DebloatApp) -> Void) {
        if let index = apps.firstIndex(where: { $0.id == url }) { change(&apps[index]) }
        if let index = installers.firstIndex(where: { $0.id == url }) { change(&installers[index]) }
    }

    // MARK: Choice

    var rows: [DebloatApp] { apps + installers }

    func row(_ url: URL) -> DebloatApp? { rows.first { $0.id == url } }

    /// An app can be ticked once its plan is found and nothing blocks it.
    func canTick(_ row: DebloatApp) -> Bool { row.plan != nil && row.plan?.blocker == nil }

    func isTicked(_ row: DebloatApp) -> Bool { canTick(row) && ticked.contains(row.id) }

    func setTicked(_ on: Bool, _ row: DebloatApp) {
        guard canTick(row) else { return }
        if on { ticked.insert(row.id) } else { ticked.remove(row.id) }
    }

    func canChoose(_ leftover: Leftover) -> Bool { !leftover.needsAdministrator || canUseAdministrator }

    /// The plan's note, or in hardcore mode the warning for an app's own documents (section 4.5, security 5).
    func note(for leftover: Leftover, of row: DebloatApp) -> String? {
        if let note = leftover.note { return note }
        let path = leftover.url.path
        let inContainers = path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
        return hardcore.isOn && inContainers ? "May hold documents you made in \(row.app.name)." : nil
    }

    func isChosen(_ leftover: Leftover, of row: DebloatApp) -> Bool {
        guard canChoose(leftover) else { return false }
        let note = note(for: leftover, of: row)
        if let choice = choices[row.id]?[leftover.url], choice.note == note { return choice.chosen }
        return leftover.evidence.preselected && note == nil
    }

    func setChosen(_ chosen: Bool, _ leftover: Leftover, of row: DebloatApp) {
        guard canChoose(leftover) else { return }
        choices[row.id, default: [:]][leftover.url] = Choice(chosen: chosen, note: note(for: leftover, of: row))
    }

    /// "Also used by Xcode-beta": runtimes belong to CoreSimulator, which every installed Xcode shares (security 10).
    func runtimeNote(_ row: DebloatApp) -> String? {
        let others = allApps.filter { $0.url != row.app.url && profiles.profile(for: $0.bundleIdentifier)?.simulatorRuntimes == true }
        return others.isEmpty ? nil : "Also used by \(others.map(\.name).joined(separator: ", "))"
    }

    /// Hardcore mode: selected unless another Xcode shares them. Trash mode: never preselected, because they are
    /// deleted, not moved to the Trash (section 4.4, ux 2).
    func runtimesChosen(_ row: DebloatApp) -> Bool {
        guard !row.runtimes.isEmpty else { return false }
        let note = runtimeNote(row)
        if let choice = runtimeChoices[row.id], choice.note == note { return choice.chosen }
        return hardcore.isOn && note == nil
    }

    func setRuntimesChosen(_ chosen: Bool, _ row: DebloatApp) {
        runtimeChoices[row.id] = Choice(chosen: chosen, note: runtimeNote(row))
    }

    func chosenLeftovers(_ row: DebloatApp) -> [Leftover] {
        (row.plan?.leftovers ?? []).filter { isChosen($0, of: row) }
    }

    /// What the current selection moves or deletes for this row; zero while it is unticked.
    func selectedBytes(_ row: DebloatApp) -> UInt64 {
        guard isTicked(row), let plan = row.plan else { return 0 }
        let leftovers = chosenLeftovers(row).reduce(plan.appMeasurement.allocated) { $0 + $1.measurement.allocated }
        return leftovers + (runtimesChosen(row) ? row.runtimeBytes : 0)
    }

    var tickedRows: [DebloatApp] { rows.filter(isTicked) }

    /// Moved to the Trash, or deleted in hardcore mode, by the Uninstaller.
    var bytesToRemove: UInt64 { tickedRows.reduce(0) { $0 + selectedBytes($1) - (runtimesChosen($1) ? $1.runtimeBytes : 0) } }
    /// Deleted by CoreSimulator's tool, in either mode.
    var runtimeBytesToDelete: UInt64 { tickedRows.reduce(0) { $0 + (runtimesChosen($1) ? $1.runtimeBytes : 0) } }

    /// What exists: every removable app with everything it installed.
    var totalBytes: UInt64 { rows.reduce(0) { $0 + $1.total } }
    var isMeasuring: Bool { !hasLoadedApps || rows.contains { $0.plan == nil } }

    /// The footer: what goes where (section 4.2).
    var footerText: String {
        let count = tickedRows.count
        guard count > 0 else { return rows.isEmpty ? "Nothing to remove." : "Tick the apps you want to remove." }
        let apps = count == 1 ? "1 app" : "\(count) apps"
        if hardcore.isOn { return "\(apps), frees up to \((bytesToRemove + runtimeBytesToDelete).formattedBytes)" }
        let runtimes = runtimeBytesToDelete > 0 ? " · \(runtimeBytesToDelete.formattedBytes) deleted now" : ""
        return "\(apps), \(bytesToRemove.formattedBytes) to the Trash\(runtimes)"
    }

    // MARK: Remove

    func beginRemove() {
        let chosenRows = tickedRows
        guard !chosenRows.isEmpty, confirmation == nil else { return }
        var jobs: [UninstallJob] = []
        var rows: [TrashSheetRow] = []
        var notes: [String] = []
        var runtimes: [(xcode: InstalledApp, runtimes: [SimRuntime])] = []
        var administratorItems = 0
        var breaksDeveloperTools = false
        for row in chosenRows {
            guard let plan = row.plan else { continue }
            let leftovers = chosenLeftovers(row)
            jobs.append(UninstallJob(plan: plan, leftovers: Set(leftovers.map(\.url))))
            rows.append(TrashSheetRow(url: plan.app.url, bytes: plan.appMeasurement.allocated))
            rows += leftovers.map { TrashSheetRow(url: $0.url, bytes: $0.measurement.allocated) }
            administratorItems += leftovers.filter(\.needsAdministrator).count + (Self.isOwnedBySystem(plan.app.url) ? 1 : 0)
            if runtimesChosen(row) { runtimes.append((row.app, row.runtimes)) }
            breaksDeveloperTools = breaksDeveloperTools || pointsInside(row.app.url)
            var labels: [String] = []
            for label in plan.bundleLaunchdLabels + leftovers.compactMap(\.launchdLabel) where !labels.contains(label) { labels.append(label) }
            notes += labels.map { "Stops background item \($0)" }
            if leftovers.contains(where: { $0.url.path.contains("/private/var/db/receipts/") }) {
                notes.append("Removes the package receipts of \(plan.app.name), so macOS no longer lists it as installed.")
            }
            notes += plan.notes
        }
        let names = chosenRows.map(\.app.name)
        notes.insert("Asks \(Self.list(names)) to quit first, if \(names.count == 1 ? "it's" : "they're") open.", at: 0)
        if !runtimes.isEmpty {
            let all = runtimes.flatMap(\.runtimes)
            let bytes = all.reduce(0) { $0 + $1.bytes }
            notes.insert("First deletes \(all.count == 1 ? "1 simulator runtime" : "\(all.count) simulator runtimes") (\(all.map(\.name).joined(separator: ", ")), \(bytes.formattedBytes)) with Xcode's own tool. They can't go to the Trash.", at: 1)
        }
        if administratorItems > 0 && canUseAdministrator {
            notes.append("macOS asks for your administrator password for \(administratorItems == 1 ? "1 item" : "\(administratorItems) items") owned by the system.")
            if !hardcore.isOn {
                notes.append("Finder may ask for your administrator password when you empty the Trash, because these belong to the system.")
            }
        }
        if breaksDeveloperTools { notes.append(Self.developerToolsNote) }
        confirmation = DebloatConfirmation(
            mode: hardcore.mode, jobs: jobs, runtimes: runtimes, rows: rows, notes: notes, breaksDeveloperTools: breaksDeveloperTools
        )
    }

    /// Section 4.6: simulator runtimes first, while Xcode and CoreSimulator are still there; then one
    /// `uninstall(jobs)` for every app, so at most one administrator dialog. An app that fails is reported and the
    /// others go on.
    func confirm() async {
        guard let pending = confirmation, pending.report == nil, !pending.isWorking else { return }
        confirmation?.isWorking = true
        defer { confirmation?.isWorking = false }
        var messages: [String] = []
        var notMoved: [URL: String] = [:]
        var kept = Set<URL>()
        var runtimesDeleted: [InstalledApp] = []
        for (xcode, runtimes) in pending.runtimes {
            do {
                for runtime in runtimes { try await runtimeTool.delete(runtime, xcode: xcode.url) }
                runtimesDeleted.append(xcode)
            } catch {
                // Without Xcode's CoreSimulator nothing could delete them later: they would stay in SIP-restricted AssetsV2.
                kept.insert(xcode.url)
                messages.append("Simulator runtimes couldn't be deleted, so \(xcode.name) was kept: without it, nothing can delete them.")
            }
        }
        let jobs = pending.jobs.filter { !kept.contains($0.plan.app.url) }
        for job in pending.jobs where kept.contains(job.plan.app.url) {
            for url in [job.plan.app.url] + job.leftovers { notMoved[url] = "its simulator runtimes couldn't be deleted." }
        }
        let batch = jobs.isEmpty
            ? UninstallBatchReport(report: TrashReport(batch: UUID(), outcomes: []), skipped: [:])
            : await uninstallJobs(jobs, pending.mode)
        for job in jobs {
            guard let error = batch.skipped[job.plan.app.url] else { continue }
            messages.append("\(job.plan.app.name) was skipped: \(error.localizedDescription)")
            for url in [job.plan.app.url] + job.leftovers { notMoved[url] = "\(job.plan.app.name) was skipped." }
        }
        let gone = Set(batch.report.outcomes.compactMap { outcome -> URL? in
            switch outcome {
            case .trashed(let url, _), .deleted(let url): url
            default: nil
            }
        })
        for xcode in runtimesDeleted where !gone.contains(xcode.url) {
            messages.append("Simulator runtimes were deleted; \(xcode.name) is still installed.")
        }
        confirmation?.report = batch.report
        confirmation?.notMoved = notMoved
        confirmation?.message = messages.isEmpty ? nil : messages.joined(separator: "\n")
        // Removed apps leave the list; the rest are planned again, since their content changed.
        ticked.subtract(gone)
        if uninstaller != nil { await rescan() }
    }

    // MARK: Helpers

    private func pointsInside(_ bundle: URL) -> Bool {
        // xcode-select writes an absolute path. No standardizing: NSString's drops /private from paths that exist.
        guard let link = developerDirectory(), link.hasPrefix("/") else { return false }
        return link == bundle.path || link.hasPrefix(bundle.path + "/")
    }

    nonisolated static func xcodeSelectLink() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink("/private/var/db/xcode_select_link", &buffer, Int(PATH_MAX))
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A bundle this user can't move: Apple's App Store apps are root-owned (feasibility-apple-apps F4).
    static func isOwnedBySystem(_ url: URL) -> Bool {
        Darwin.access(url.path, W_OK) != 0
    }

    static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
