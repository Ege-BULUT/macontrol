import AppKit
import Foundation
import MacontrolCore
import Observation
import Safety
import ScanEngine
import Uninstaller

/// One list section: third-party apps, Apple's removable apps, or apps that are part of macOS.
struct AppSection: Identifiable {
    let kind: AppKind
    let apps: [InstalledApp]
    var id: AppKind { kind }
}

/// The open confirmation sheet, fixed when it opens.
struct UninstallConfirmation: Identifiable, RemovalConfirmation {
    let id = UUID()
    let plan: UninstallPlan
    /// Chosen leftovers in plan order. With the bundle, exactly what `Uninstaller.uninstall` trashes.
    let leftovers: [Leftover]
    let appIsRunning: Bool
    var isWorking = false
    var report: TrashReport?
    var errorMessage: String?
    /// The mode it opened with, and the rest of hardcore mode's state (DESIGN-debloat section 1.1).
    var run = RemovalRun()
    /// Rows the administrator helper removes: root-owned leftovers, and the bundle when root owns it.
    var adminCount = 0

    var rows: [TrashSheetRow] {
        [TrashSheetRow(url: plan.app.url, bytes: plan.appMeasurement.allocated)]
            + leftovers.map { TrashSheetRow(url: $0.url, bytes: $0.measurement.allocated) }
    }

    /// Every step besides the moves, then what macontrol leaves alone: the preview lists all of it (F-0069).
    var notes: [String] {
        backgroundItems.map { "Stops background item \($0)" } + plan.notes
    }

    /// The launchd jobs the uninstall boots out, in the order it does.
    private var backgroundItems: [String] {
        var labels: [String] = []
        for label in plan.bundleLaunchdLabels + leftovers.compactMap(\.launchdLabel) where !labels.contains(label) {
            labels.append(label)
        }
        return labels
    }

    /// Why the uninstall stopped, and what already ran. The quit and the bootouts come before any move,
    /// so a late stop leaves them done even though nothing is in the Trash (F-0069).
    func failureMessage(for error: any Error) -> String {
        let reason = error.localizedDescription
        let askedToQuit: Bool
        switch error as? UninstallError {
        case .stillRunning?: askedToQuit = true
        case .bootoutFailed?: askedToQuit = appIsRunning
        default: return "The uninstall stopped before moving anything: \(reason)"
        }
        var ran = askedToQuit ? ["\(plan.app.name) was asked to quit"] : []
        if !backgroundItems.isEmpty {
            ran.append("these background items may have been stopped: \(backgroundItems.joined(separator: ", "))")
        }
        let nothing = run.isPermanent ? "Nothing was removed" : "Nothing was moved to the Trash"
        return "\(nothing), but \(ran.joined(separator: ", and ")). \(reason)"
    }
}

/// A leftover the user checked or unchecked, with what the leftover showed when they did.
private struct LeftoverChoice {
    let chosen: Bool
    let note: String?
    let wasPreselected: Bool
}

@Observable
public final class UninstallModel {
    public private(set) var apps: [InstalledApp]
    public var selectedApp: InstalledApp.ID?
    /// The plan of the selected app, once found.
    public private(set) var plan: UninstallPlan?
    var query = "" { didSet { dropHiddenSelection() } }
    /// Mirrors the list's `@AppStorage` choice, which the view writes here.
    var filter = AppFilter.all { didSet { dropHiddenSelection() } }
    var sort = AppSort.nameAscending
    /// Bundle sizes, measured lazily as rows appear.
    var sizes: [URL: UInt64] = [:]
    /// Last plan per app, shown at once on reselect while the app is read again.
    var plans: [URL: UninstallPlan] = [:]
    var runningBundleIDs: Set<String> = []
    private(set) var hasLoadedApps: Bool
    private(set) var appsError: String?
    private(set) var planError: String?
    var confirmation: UninstallConfirmation?
    /// The app's one switch; `AppModel` hands every screen the same instance.
    var hardcore = HardcoreMode()
    var support = RemovalSupport()
    /// The uninstaller can hand root-owned leftovers to the administrator helper. False: v1, they are Reveal in Finder only.
    var canUseAdministrator: Bool
    /// Whether the bundle itself needs the helper: an App Store app is owned by root.
    var needsAdministrator: (URL) -> Bool = { ProtectedPaths.refusal(for: $0) == .needsAdministrator }

    /// Per app, per leftover: what the user checked or unchecked, across app switches and re-scans. Every other
    /// leftover follows the current plan's `isPreselected` (F-0011, F-0022).
    private var choices: [URL: [URL: LeftoverChoice]] = [:]

    private let uninstaller: Uninstaller?
    private let engine: ScanEngine?
    /// Apps being measured, each with the callers waiting for that attempt.
    private var measuring: [URL: [CheckedContinuation<Void, Never>]] = [:]
    /// Bundle walks allowed at once. Every visible row asks for its size, and each is a full walk.
    private var freeMeasureSlots = 3
    private var measureQueue: [CheckedContinuation<Void, Never>] = []

    public init(uninstaller: Uninstaller?, apps: [InstalledApp] = [], plan: UninstallPlan? = nil, engine: ScanEngine? = ScanEngine()) {
        self.uninstaller = uninstaller
        self.engine = engine
        self.canUseAdministrator = uninstaller?.canUseAdministrator ?? false
        self.apps = apps
        self.hasLoadedApps = !apps.isEmpty
        self.selectedApp = plan?.app.id
        if let plan {
            plans[plan.app.url] = plan
            show(plan)
        }
    }

    // MARK: App list

    /// Reads the installed apps again, on every visit: apps get installed, updated and removed meanwhile.
    /// A plan or size from another copy of an app (an update replaced the bundle) is dropped.
    func loadApps() async {
        guard let uninstaller else { return }
        defer { hasLoadedApps = true }
        let found: [InstalledApp]
        do {
            found = try await uninstaller.installedApps()
        } catch {
            appsError = error.localizedDescription
            return
        }
        appsError = nil
        let before = Dictionary(apps.map { ($0.url, $0.identity) }, uniquingKeysWith: { first, _ in first })
        for app in found where before[app.url] != app.identity { sizes[app.url] = nil }
        let current = Dictionary(found.map { ($0.url, $0.identity) }, uniquingKeysWith: { first, _ in first })
        plans = plans.filter { current[$0.key] == $0.value.app.identity }
        apps = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Apps the search matches, before the filter.
    private var matching: [InstalledApp] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(needle)
        }
    }

    /// How many apps each filter would show for the current search.
    func count(_ filter: AppFilter) -> Int { matching.count(where: filter.includes) }

    /// The shown apps, sorted within each section. Sizes are read only when sorting by size, so a new size
    /// otherwise redraws its own row, not the list.
    var sections: [AppSection] {
        let visible = sort.sorted(matching.filter(filter.includes)) { self.sizes[$0.url] }
        return AppKind.listOrder.compactMap { kind in
            let members = visible.filter { $0.kind == kind }
            return members.isEmpty ? nil : AppSection(kind: kind, apps: members)
        }
    }

    /// Return would otherwise uninstall an app the search or the filter no longer shows.
    private func dropHiddenSelection() {
        if let selectedApp, !matching.contains(where: { $0.id == selectedApp && filter.includes($0) }) { self.selectedApp = nil }
    }

    /// Sorting by size needs every app's size, not only the rows on screen. Three walks at a time, as for rows.
    func measureAll() async {
        await withDiscardingTaskGroup { group in
            for app in apps { group.addTask { await self.measureIfNeeded(app) } }
        }
    }

    func measureIfNeeded(_ app: InstalledApp) async {
        guard uninstaller != nil, let engine else { return }
        // Another caller is measuring it. Its attempt ends without a size if that caller is cancelled (its row
        // scrolled away, or Size sort was left), so wait for it and measure again if the size is still missing.
        while sizes[app.url] == nil, measuring[app.url] != nil {
            await withCheckedContinuation { measuring[app.url, default: []].append($0) }
        }
        guard !Task.isCancelled, sizes[app.url] == nil else { return }
        measuring[app.url] = []
        defer { measuring.removeValue(forKey: app.url)?.forEach { $0.resume() } }
        await takeMeasureSlot()
        defer { returnMeasureSlot() }
        // A row scrolled away while waiting, or its plan measured the bundle meanwhile.
        guard !Task.isCancelled, sizes[app.url] == nil else { return }
        if let measurement = try? await engine.measure(app.url) { sizes[app.url] = measurement.allocated }
    }

    private func takeMeasureSlot() async {
        if freeMeasureSlots > 0 {
            freeMeasureSlots -= 1
        } else {
            await withCheckedContinuation { measureQueue.append($0) }
        }
    }

    private func returnMeasureSlot() {
        if measureQueue.isEmpty { freeMeasureSlots += 1 } else { measureQueue.removeFirst().resume() }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        app.bundleIdentifier.map(runningBundleIDs.contains) ?? false
    }

    // MARK: Plan

    var selected: InstalledApp? { apps.first { $0.id == selectedApp } }

    /// Finds leftovers for the selected app, every time it is selected: a plan goes stale as the app updates or
    /// writes new data. The last plan shows meanwhile. Called from `.task(id: selectedApp)`, which cancels stale runs.
    func loadPlan() async {
        planError = nil
        guard let app = selected else { plan = nil; return }
        refreshRunning(app)
        if let cached = plans[app.url] { show(cached) } else { plan = nil }
        guard let uninstaller else { return }
        // Arrow keys move through the list faster than a plan is found.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        do {
            let found = try await uninstaller.plan(for: app)
            plans[app.url] = found
            if selectedApp == app.id { show(found) }
        } catch {
            if selectedApp == app.id && !(error is CancellationError) { planError = error.localizedDescription }
        }
    }

    /// Scan Again: the app list and the selected app's leftovers, read from disk with fresh identities.
    func rescan() async {
        if let selectedApp { plans[selectedApp] = nil }
        plan = nil
        await loadApps()
        await loadPlan()
    }

    private func show(_ plan: UninstallPlan) {
        self.plan = plan
        sizes[plan.app.url] = plan.appMeasurement.allocated
        // A check stands only while the leftover looks as it did when the user gave it. One that has since gained
        // a note ("Also used by X") or lost preselection goes back to the plan's default: unchecked.
        for leftover in plan.leftovers {
            guard let choice = choices[plan.app.url]?[leftover.url], choice.chosen else { continue }
            if choice.note != note(for: leftover) || choice.wasPreselected != leftover.isPreselected {
                choices[plan.app.url]?[leftover.url] = nil
            }
        }
    }

    private func refreshRunning(_ app: InstalledApp) {
        guard uninstaller != nil, let id = app.bundleIdentifier else { return }
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            runningBundleIDs.remove(id)
        } else {
            runningBundleIDs.insert(id)
        }
    }

    // MARK: Leftover choice

    /// Chosen leftovers of the shown plan.
    var leftoverSelection: Set<URL> { Set(chosenLeftovers.map(\.url)) }

    /// Nothing is chosen for an app that can't be uninstalled. Root-owned leftovers only with the administrator
    /// helper; without it, v1 offers Reveal in Finder for them.
    func isChosen(_ leftover: Leftover) -> Bool {
        guard canUninstall, canChoose(leftover), let plan else { return false }
        // A check given under another note (hardcore mode switched since) no longer stands.
        if let choice = choices[plan.app.url]?[leftover.url], choice.note == note(for: leftover) { return choice.chosen }
        return leftover.isPreselected && documentsNote(for: leftover) == nil
    }

    /// What the row says about a leftover: the plan's note, or in hardcore mode the documents warning.
    func note(for leftover: Leftover) -> String? {
        leftover.note ?? documentsNote(for: leftover)
    }

    /// In hardcore mode an app's containers are not preselected: they may hold what the user made in the app, and
    /// nothing puts them back (DESIGN-debloat section 4.5, r2: sec 5).
    private func documentsNote(for leftover: Leftover) -> String? {
        guard hardcore.isOn, let plan else { return nil }
        let path = leftover.url.path
        let isContainer = path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
        return isContainer ? "May hold documents you made in \(plan.app.name)." : nil
    }

    func canChoose(_ leftover: Leftover) -> Bool {
        !leftover.needsAdministrator || canUseAdministrator
    }

    func setChosen(_ chosen: Bool, _ leftover: Leftover) {
        guard canUninstall, canChoose(leftover), let plan else { return }
        choices[plan.app.url, default: [:]][leftover.url] =
            LeftoverChoice(chosen: chosen, note: note(for: leftover), wasPreselected: leftover.isPreselected)
    }

    func toggle(_ urls: Set<URL>) {
        let targets = (plan?.leftovers ?? []).filter { urls.contains($0.url) && canChoose($0) }
        let turnOn = targets.contains { !isChosen($0) }
        for leftover in targets { setChosen(turnOn, leftover) }
    }

    var chosenLeftovers: [Leftover] { (plan?.leftovers ?? []).filter(isChosen) }

    /// Only for the selected app: a plan still shown for an app the search hid must not be uninstalled.
    var canUninstall: Bool {
        guard let plan, plan.app.id == selectedApp else { return false }
        return plan.app.kind != .builtIn && plan.blocker == nil
    }

    // MARK: Uninstall

    func beginUninstall() {
        guard let plan, canUninstall, confirmation == nil else { return }
        // The app may have been opened since it was selected; the sheet must say it will be asked to quit.
        refreshRunning(plan.app)
        var confirmation = UninstallConfirmation(plan: plan, leftovers: chosenLeftovers, appIsRunning: isRunning(plan.app))
        confirmation.run = RemovalRun(mode: hardcore.mode, urls: confirmation.rows.map(\.url), support: support)
        if canUseAdministrator {
            confirmation.adminCount = confirmation.leftovers.count(where: \.needsAdministrator) + (needsAdministrator(plan.app.url) ? 1 : 0)
        }
        self.confirmation = confirmation
    }

    /// "Delete Permanently" after the restore point failed: go on without one.
    func confirmWithoutRestorePoint() async {
        confirmation?.run.restorePointProblem = nil
        confirmation?.run.goesOnWithoutRestorePoint = true
        await confirmUninstall()
    }

    /// Runs exactly the confirmed uninstall, in the mode the sheet opened with, then applies each outcome.
    func confirmUninstall() async {
        guard let pending = confirmation, pending.report == nil, !pending.isWorking, pending.run.restorePointProblem == nil else { return }
        // From here on only this sheet is written to: the next one can be another app's.
        confirmation?.isWorking = true
        defer { confirmation.ifStill(pending.id) { $0.isWorking = false } }
        guard let run = await support.makeRestorePoint(in: self, \.confirmation) else { return }
        let chosen = Set(pending.leftovers.map(\.url))
        do {
            let (report, freed) = try await support.measuring(run.mode, pending.rows.map(\.url)) {
                if let uninstaller {
                    try await uninstaller.uninstall(pending.plan, leftovers: chosen, mode: run.mode, restorePoint: run.restorePoint)
                } else {
                    // Demo data: nothing real to move.
                    TrashReport(batch: UUID(), outcomes: pending.rows.map { .refused($0.url, .notImplemented) })
                }
            }
            apply(report, to: pending.plan)
            confirmation.ifStill(pending.id) {
                $0.run.freed = freed
                $0.report = report
            }
        } catch {
            confirmation.ifStill(pending.id) { $0.errorMessage = pending.failureMessage(for: error) }
            // The plan may be stale (an update replaced the bundle, the app recreated a folder), and retrying it
            // would fail the same way. Read the app and its leftovers again for the next try.
            if uninstaller != nil { await rescan() }
        }
    }

    /// A trashed or deleted app leaves the list; otherwise its removed leftovers leave its plan.
    func apply(_ report: TrashReport, to plan: UninstallPlan) {
        let trashed = report.removedURLs
        let appID = plan.app.id
        if trashed.contains(plan.app.url) {
            apps.removeAll { $0.id == appID }
            plans[appID] = nil
            sizes[appID] = nil
            choices[appID] = nil
            if selectedApp == appID {
                selectedApp = nil
                self.plan = nil
            }
            return
        }
        // A plan found while the sheet was open is newer than the sheet's; take the moved items out of that one.
        var remaining = plans[appID] ?? plan
        remaining.leftovers.removeAll { trashed.contains($0.url) }
        plans[appID] = remaining
        if self.plan?.app.id == appID {
            self.plan = remaining
        }
    }
}
