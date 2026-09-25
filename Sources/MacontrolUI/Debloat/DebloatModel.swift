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
    /// Why the row can't be ticked: its plan could not be found, or its runtimes could not be listed.
    var failure: String?
    var id: URL { app.url }

    var runtimeBytes: UInt64 { runtimes.reduce(0) { $0 + $1.bytes } }
    /// The bundle, everything the plan found and the runtimes.
    var total: UInt64 {
        guard let plan else { return 0 }
        return plan.leftovers.reduce(plan.appMeasurement.allocated + runtimeBytes) { $0 + $1.measurement.allocated }
    }
}

/// A ticked Xcode's step before the uninstall: what CoreSimulator listed when the sheet opened, and what it deletes.
struct RuntimeStep {
    let xcode: InstalledApp
    let listed: [SimRuntime]
    let runtimes: [SimRuntime]
}

/// The open confirmation, fixed when it opens: its mode, jobs and runtimes do not follow later changes.
struct DebloatConfirmation: Identifiable {
    let id = UUID()
    let mode: DeletionMode
    /// Every ticked app with its chosen leftovers, in list order.
    let jobs: [UninstallJob]
    /// One per ticked Xcode, run before the uninstall.
    let runtimes: [RuntimeStep]
    let rows: [TrashSheetRow]
    let notes: [String]
    /// Items the administrator helper moves: they have no Undo in History (D12).
    let administratorItems: Int
    /// `xcode-select` points into a bundle being removed.
    let breaksDeveloperTools: Bool
    var isWorking = false
    var report: TrashReport?
    var notMoved: [URL: String] = [:]
    var message: String?
    /// An Xcode that `xcode-select` points into is gone.
    var brokeDeveloperTools = false

    /// The `xcode-select --reset` line: before the run when it would break git and clang, after it when it did (review 2, 9).
    var showsResetCommand: Bool { report == nil ? breaksDeveloperTools : brokeDeveloperTools }

    var runtimeBytes: UInt64 { runtimes.flatMap(\.runtimes).reduce(0) { $0 + $1.bytes } }
    var rowBytes: UInt64 { rows.reduce(0) { $0 + $1.bytes } }

    /// The sheet's message: what can be put back, and from where.
    var summary: String {
        if mode == .permanent {
            return "They skip the Trash and can't be put back. Frees up to \((rowBytes + runtimeBytes).formattedBytes)."
        }
        let names = DebloatModel.list(jobs.map(\.plan.app.name))
        var text = "\(names) and what \(jobs.count == 1 ? "it" : "they") installed move to the Trash, and the space is freed when you empty it. "
        text += administratorItems == 0
            ? "Put them back from History until then."
            : "Items owned by the system can't be put back from History: drag them out of the Trash in Finder. The rest can be put back from History until then."
        if runtimeBytes > 0 { text += " The simulator runtimes are deleted now and can't be put back." }
        return text
    }
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
    /// All of macOS's own apps together, once each is measured; nil until then.
    var systemAppsSize: UInt64? {
        locked.allSatisfy { lockedSizes[$0.url] != nil } ? locked.reduce(0) { $0 + (lockedSizes[$1.url] ?? 0) } : nil
    }
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
        for app in (apps + installers).filter({ $0.plan == nil && $0.failure == nil }).map(\.app) {
            guard !Task.isCancelled else { return }
            let plan: UninstallPlan
            do {
                plan = try await uninstaller.plan(for: app)
            } catch {
                // A cancelled visit finds it next time.
                if !(error is CancellationError) { update(app.url) { $0.failure = "Couldn't look at it: \(error.localizedDescription)" } }
                continue
            }
            var runtimes: [SimRuntime] = []
            var failure: String?
            if hasRuntimes(app) {
                do {
                    runtimes = try await runtimeTool.list(xcode: app.url)
                } catch {
                    // "Couldn't look" is not "there are none": removing Xcode takes CoreSimulator, the only tool that
                    // deletes runtimes, and would leave them in SIP-restricted AssetsV2 for good (review 1).
                    failure = "Couldn't list its simulator runtimes, so \(app.name) is kept: without it, nothing could delete them. Open \(app.name) once, then Scan Again."
                }
            }
            update(app.url) { $0.plan = plan; $0.runtimes = runtimes; $0.failure = failure }
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
    func canTick(_ row: DebloatApp) -> Bool { row.plan != nil && row.plan?.blocker == nil && row.failure == nil }

    func isTicked(_ row: DebloatApp) -> Bool { canTick(row) && ticked.contains(row.id) }

    func setTicked(_ on: Bool, _ row: DebloatApp) {
        guard canTick(row) else { return }
        if on { ticked.insert(row.id) } else { ticked.remove(row.id) }
    }

    func canChoose(_ leftover: Leftover) -> Bool { !leftover.needsAdministrator || canUseAdministrator }

    /// The plan's note; CoreSimulator while runtimes stay; in hardcore mode the warning for an app's own documents
    /// (section 4.5, security 5).
    func note(for leftover: Leftover, of row: DebloatApp) -> String? {
        if let note = leftover.note, note.hasPrefix(SimRuntimeTool.heldNote) {
            // CoreSimulator.framework holds the only tool that deletes runtimes. The plan holds it back on every screen;
            // here it waits only while runtimes stay (review 1, 2; review 2, 1).
            let rest = note.dropFirst(SimRuntimeTool.heldNote.count).trimmingCharacters(in: .whitespaces)
            let held = !row.runtimes.isEmpty && !runtimesChosen(row)
                ? "Holds the only tool that deletes simulator runtimes. Without it, the \(row.runtimeBytes.formattedBytes) of runtimes left unticked stay on this Mac until you reinstall \(row.app.name)."
                : nil
            let text = [held, rest].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
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
        let others = allApps.filter { $0.url != row.app.url && hasRuntimes($0) }
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
    var bytesToRemove: UInt64 {
        Self.sumOnce(tickedRows.flatMap { row in
            [(row.id, row.plan?.appMeasurement.allocated ?? 0)] + chosenLeftovers(row).map { ($0.url, $0.measurement.allocated) }
        })
    }
    /// Deleted by CoreSimulator's tool, in either mode.
    var runtimeBytesToDelete: UInt64 { Self.sumOnce(tickedRows.filter(runtimesChosen).flatMap { $0.runtimes.map { ($0.id, $0.bytes) } }) }

    /// What exists: every removable app with everything it installed.
    var totalBytes: UInt64 {
        Self.sumOnce(rows.flatMap { row in
            [(row.id, row.plan?.appMeasurement.allocated ?? 0)] + (row.plan?.leftovers ?? []).map { ($0.url, $0.measurement.allocated) }
        }) + Self.sumOnce(rows.flatMap { $0.runtimes.map { ($0.id, $0.bytes) } })
    }

    /// Each folder or runtime once: GarageBand, Logic Pro and MainStage share folders, and every Xcode lists the same
    /// runtimes (review 5).
    private static func sumOnce<Key: Hashable>(_ items: [(Key, UInt64)]) -> UInt64 {
        var seen = Set<Key>()
        return items.reduce(0) { seen.insert($1.0).inserted ? $0 + $1.1 : $0 }
    }
    var isMeasuring: Bool { !hasLoadedApps || rows.contains { $0.plan == nil && $0.failure == nil } }

    /// The footer: what goes where (section 4.2).
    var footerText: String {
        let count = tickedRows.count
        guard count > 0 else { return rows.isEmpty && !isMeasuring ? "Nothing to remove." : "Tick the apps you want to remove." }
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
        var runtimes: [RuntimeStep] = []
        var administratorItems = 0
        var breaksDeveloperTools = false
        // A shared folder ticked in two rows goes once, with the first app (review 5).
        var seen = Set<URL>()
        var seenRuntimes = Set<String>()
        for row in chosenRows {
            guard let plan = row.plan else { continue }
            let leftovers = chosenLeftovers(row).filter { seen.insert($0.url).inserted }
            jobs.append(UninstallJob(plan: plan, leftovers: Set(leftovers.map(\.url))))
            rows.append(TrashSheetRow(url: plan.app.url, bytes: plan.appMeasurement.allocated))
            rows += leftovers.map { TrashSheetRow(url: $0.url, bytes: $0.measurement.allocated) }
            administratorItems += leftovers.filter(\.needsAdministrator).count + (Self.isOwnedBySystem(plan.app.url) ? 1 : 0)
            // Every Xcode gets its step, runtimes ticked or not: it is checked and listed again before it goes (review 2, 2).
            if hasRuntimes(row.app) {
                let fresh = runtimesChosen(row) ? row.runtimes.filter { seenRuntimes.insert($0.id).inserted } : []
                runtimes.append(RuntimeStep(xcode: row.app, listed: row.runtimes, runtimes: fresh))
            }
            breaksDeveloperTools = breaksDeveloperTools || pointsInside(row.app.url)
            var labels: [String] = []
            for label in plan.bundleLaunchdLabels + leftovers.compactMap(\.launchdLabel) where !labels.contains(label) { labels.append(label) }
            notes += labels.map { "Stops background item \($0)" }
            if leftovers.contains(where: { $0.url.path.contains("/private/var/db/receipts/") }) {
                notes.append("Removes the package receipts of \(plan.app.name), so macOS no longer lists it as installed.")
            }
            // What stays is shown in the list, not as something that happens (review 2, 10).
            notes += plan.notes.filter { !$0.hasPrefix(AppleProfile.Kept.notePrefix) }
        }
        // In the order they happen (review 3).
        let names = chosenRows.map(\.app.name)
        var first = ["Asks \(Self.list(names)) to quit first, if \(names.count == 1 ? "it's" : "they're") open."]
        let all = runtimes.flatMap(\.runtimes)
        if !all.isEmpty {
            let bytes = all.reduce(0) { $0 + $1.bytes }
            first.append("Then deletes \(all.count == 1 ? "1 simulator runtime" : "\(all.count) simulator runtimes") (\(all.map(\.name).joined(separator: ", ")), \(bytes.formattedBytes)) with Xcode's own tool, which shuts down any simulator still running. They can't go to the Trash.")
        }
        // Review 2, 4: the runtimes left unticked stay, and the sheet says so.
        var staying: [String: UInt64] = [:]
        for step in runtimes { for runtime in step.listed where !seenRuntimes.contains(runtime.id) { staying[runtime.id] = runtime.bytes } }
        if !staying.isEmpty {
            let xcodes = runtimes.map(\.xcode.url)
            let others = allApps.filter { !xcodes.contains($0.url) && hasRuntimes($0) }.map(\.name)
            let bytes = staying.values.reduce(0, +).formattedBytes
            first.append(others.isEmpty
                ? "The simulator runtimes left unticked (\(bytes)) stay on this Mac until you reinstall \(Self.list(runtimes.map(\.xcode.name)))."
                : "The simulator runtimes left unticked (\(bytes)) stay on this Mac for \(Self.list(others)).")
        }
        notes.insert(contentsOf: first, at: 0)
        if administratorItems > 0 && canUseAdministrator {
            notes.append("macOS asks for your administrator password for \(administratorItems == 1 ? "1 item" : "\(administratorItems) items") owned by the system.")
            if !hardcore.isOn {
                notes.append("Finder may ask for your administrator password when you empty the Trash, because these belong to the system.")
            }
        }
        if breaksDeveloperTools { notes.append(Self.developerToolsNote) }
        confirmation = DebloatConfirmation(
            mode: hardcore.mode, jobs: jobs, runtimes: runtimes, rows: rows, notes: notes,
            administratorItems: canUseAdministrator ? administratorItems : 0, breaksDeveloperTools: breaksDeveloperTools
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
        var kept: [URL: String] = [:]
        var runtimesDeleted: [InstalledApp] = []
        var deleted = Set<String>()
        for step in pending.runtimes {
            let xcode = step.xcode
            // The uninstaller's cheap checks first, since deleted runtimes can't come back: an Xcode replaced since
            // the list (an App Store update) or still open keeps everything (review 3, 8). Quitting it first also
            // closes Simulator before the delete shuts down the simulators.
            var skipped: String?
            if xcode.identity == nil || FileIdentity(url: xcode.url) != xcode.identity {
                skipped = UninstallError.changedSincePlan(xcode.url).localizedDescription
            } else if let refusal = preflight(pending.jobs.first { $0.plan.app.url == xcode.url }) {
                // Every other check the uninstall makes on Xcode's job, such as a chosen leftover recreated since the
                // list (review, new cycle 1, 2).
                skipped = refusal
            } else if await !runtimeTool.quit(xcode) {
                skipped = UninstallError.stillRunning(xcode.name).localizedDescription
            } else {
                // Listed again now that Xcode is closed: a runtime that finished downloading since the sheet opened
                // would stay for good (review 2, 2). What an earlier Xcode deleted in this run is gone from both lists.
                let expected = Set(step.listed.map(\.id)).subtracting(deleted)
                do {
                    if Set(try await runtimeTool.list(xcode: xcode.url).map(\.id)).subtracting(deleted) != expected {
                        skipped = "its simulator runtimes changed after the list was made. Scan Again, then try again."
                    }
                } catch {
                    skipped = "its simulator runtimes couldn't be listed again. Scan Again, then try again."
                }
            }
            if let skipped {
                kept[xcode.url] = "\(xcode.name) was skipped."
                messages.append("\(xcode.name) was skipped: \(skipped)")
                continue
            }
            var done: [SimRuntime] = []
            do {
                for runtime in step.runtimes {
                    try await runtimeTool.delete(runtime, xcode: xcode.url)
                    done.append(runtime)
                    deleted.insert(runtime.id)
                }
            } catch {
                // Without Xcode's CoreSimulator nothing could delete them later: they would stay in SIP-restricted AssetsV2.
                // What did go is gone for good, and the message says so (review 2, 3).
                let left = step.runtimes.filter { !done.contains($0) }
                kept[xcode.url] = done.isEmpty ? "its simulator runtimes couldn't be deleted." : "some of its simulator runtimes couldn't be deleted."
                messages.append(done.isEmpty
                    ? "Simulator runtimes couldn't be deleted, so \(xcode.name) was kept: without it, nothing can delete them."
                    : "Deleted \(Self.describe(done)) for good, but \(Self.describe(left)) couldn't be deleted, so \(xcode.name) was kept: without it, nothing can delete \(left.count == 1 ? "it" : "them").")
                continue
            }
            guard !done.isEmpty else { continue }
            // The tool exits once CoreSimulator has queued the delete, and what finishes it runs from the
            // CoreSimulator.framework that goes with Xcode: Xcode goes only once the list no longer has them (review,
            // new cycle 1, 1).
            if await runtimeTool.waitUntilGone(Set(done.map(\.id)), xcode: xcode.url) {
                runtimesDeleted.append(xcode)
            } else {
                kept[xcode.url] = "its simulator runtimes were still being deleted."
                messages.append("Deleting \(Self.describe(done)) hadn't finished after a minute, so \(xcode.name) was kept: its CoreSimulator finishes the delete. Scan Again in a few minutes, then remove \(xcode.name).")
            }
        }
        let jobs = pending.jobs.filter { kept[$0.plan.app.url] == nil }
        for job in pending.jobs {
            guard let reason = kept[job.plan.app.url] else { continue }
            for url in [job.plan.app.url] + job.leftovers { notMoved[url] = reason }
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
        confirmation?.brokeDeveloperTools = jobs.contains { gone.contains($0.plan.app.url) && pointsInside($0.plan.app.url) }
        confirmation?.message = messages.isEmpty ? nil : messages.joined(separator: "\n")
        // Removed apps leave the list; the rest are planned again, since their content changed.
        ticked.subtract(gone)
        if uninstaller != nil { await rescan() }
    }

    // MARK: Helpers

    /// The uninstaller's own checks on this job, without its quit or bootout: the reason it would be skipped, or nil.
    private func preflight(_ job: UninstallJob?) -> String? {
        guard let job else { return "it is not in this run." }
        do {
            try uninstaller?.preflight(job)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// An app whose runtimes CoreSimulator lists: Xcode.
    private func hasRuntimes(_ app: InstalledApp) -> Bool {
        profiles.profile(for: app.bundleIdentifier)?.simulatorRuntimes == true
    }

    /// "iOS 26.5 and watchOS 26.5 (12.43 GB)".
    private static func describe(_ runtimes: [SimRuntime]) -> String {
        "\(list(runtimes.map(\.name))) (\(runtimes.reduce(0) { $0 + $1.bytes }.formattedBytes))"
    }

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
