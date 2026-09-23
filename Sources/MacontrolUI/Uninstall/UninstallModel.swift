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
struct UninstallConfirmation: Identifiable {
    let id = UUID()
    let plan: UninstallPlan
    /// Chosen leftovers in plan order. With the bundle, exactly what `Uninstaller.uninstall` trashes.
    let leftovers: [Leftover]
    let appIsRunning: Bool
    var isWorking = false
    var report: TrashReport?
    var errorMessage: String?

    var rows: [TrashSheetRow] {
        [TrashSheetRow(url: plan.app.url, bytes: plan.appMeasurement.allocated)]
            + leftovers.map { TrashSheetRow(url: $0.url, bytes: $0.measurement.allocated) }
    }
}

@Observable
public final class UninstallModel {
    public private(set) var apps: [InstalledApp]
    public var selectedApp: InstalledApp.ID?
    /// The plan of the selected app, once found.
    public private(set) var plan: UninstallPlan?
    var query = ""
    /// Chosen leftovers of the shown plan, seeded from `Leftover.isPreselected` only (F-0011, F-0022).
    var leftoverSelection: Set<URL> = []
    /// Bundle sizes, measured lazily as rows appear.
    var sizes: [URL: UInt64] = [:]
    var plans: [URL: UninstallPlan] = [:]
    var runningBundleIDs: Set<String> = []
    private(set) var hasLoadedApps: Bool
    private(set) var planError: String?
    var confirmation: UninstallConfirmation?

    private let uninstaller: Uninstaller?
    private let engine: ScanEngine?
    private var measuring: Set<URL> = []

    public init(uninstaller: Uninstaller?, apps: [InstalledApp] = [], plan: UninstallPlan? = nil, engine: ScanEngine? = ScanEngine()) {
        self.uninstaller = uninstaller
        self.engine = engine
        self.apps = apps
        self.hasLoadedApps = !apps.isEmpty
        self.selectedApp = plan?.app.id
        if let plan {
            plans[plan.app.url] = plan
            show(plan)
        }
    }

    // MARK: App list

    func loadApps() async {
        guard let uninstaller, !hasLoadedApps else { return }
        apps = ((try? await uninstaller.installedApps()) ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        hasLoadedApps = true
    }

    var sections: [AppSection] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let visible = needle.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(needle)
        }
        return AppKind.listOrder.compactMap { kind in
            let members = visible.filter { $0.kind == kind }
            return members.isEmpty ? nil : AppSection(kind: kind, apps: members)
        }
    }

    func measureIfNeeded(_ app: InstalledApp) async {
        guard uninstaller != nil, let engine, sizes[app.url] == nil, measuring.insert(app.url).inserted else { return }
        defer { measuring.remove(app.url) }
        if let measurement = try? await engine.measure(app.url) { sizes[app.url] = measurement.allocated }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        app.bundleIdentifier.map(runningBundleIDs.contains) ?? false
    }

    // MARK: Plan

    var selected: InstalledApp? { apps.first { $0.id == selectedApp } }

    /// Finds leftovers for the selected app. Called from `.task(id: selectedApp)`, which cancels stale runs.
    func loadPlan() async {
        planError = nil
        guard let app = selected else { plan = nil; return }
        refreshRunning(app)
        if plan?.app.id == app.id { return }
        if let cached = plans[app.url] { show(cached); return }
        plan = nil
        guard let uninstaller else { return }
        do {
            let found = try await uninstaller.plan(for: app)
            plans[app.url] = found
            if selectedApp == app.id { show(found) }
        } catch {
            if selectedApp == app.id && !(error is CancellationError) { planError = error.localizedDescription }
        }
    }

    private func show(_ plan: UninstallPlan) {
        self.plan = plan
        sizes[plan.app.url] = plan.appMeasurement.allocated
        leftoverSelection = Set(plan.leftovers.filter(\.isPreselected).map(\.url))
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

    func isChosen(_ leftover: Leftover) -> Bool { leftoverSelection.contains(leftover.url) }

    /// Root-owned leftovers are never chosen: v1 offers Reveal in Finder for them.
    func setChosen(_ chosen: Bool, _ leftover: Leftover) {
        guard !leftover.needsAdministrator else { return }
        if chosen { leftoverSelection.insert(leftover.url) } else { leftoverSelection.remove(leftover.url) }
    }

    func toggle(_ urls: Set<URL>) {
        let targets = (plan?.leftovers ?? []).filter { urls.contains($0.url) && !$0.needsAdministrator }
        let turnOn = targets.contains { !isChosen($0) }
        for leftover in targets { setChosen(turnOn, leftover) }
    }

    var chosenLeftovers: [Leftover] {
        (plan?.leftovers ?? []).filter { isChosen($0) && !$0.needsAdministrator }
    }

    var canUninstall: Bool {
        guard let plan else { return false }
        return plan.app.kind != .builtIn && plan.blocker == nil
    }

    // MARK: Uninstall

    func beginUninstall() {
        guard let plan, canUninstall, confirmation == nil else { return }
        confirmation = UninstallConfirmation(plan: plan, leftovers: chosenLeftovers, appIsRunning: isRunning(plan.app))
    }

    /// Runs exactly the confirmed uninstall, then applies each outcome.
    func confirmUninstall() async {
        guard let pending = confirmation, pending.report == nil, !pending.isWorking else { return }
        confirmation?.isWorking = true
        defer { confirmation?.isWorking = false }
        let chosen = Set(pending.leftovers.map(\.url))
        do {
            let report = if let uninstaller {
                try await uninstaller.uninstall(pending.plan, leftovers: chosen)
            } else {
                // Demo data: nothing real to move.
                TrashReport(batch: UUID(), outcomes: pending.rows.map { .refused($0.url, .notImplemented) })
            }
            apply(report, to: pending.plan)
            confirmation?.report = report
        } catch {
            confirmation?.errorMessage = "The uninstall stopped before moving anything: \(error.localizedDescription)"
        }
    }

    /// A trashed app leaves the list; otherwise its trashed leftovers leave its plan.
    func apply(_ report: TrashReport, to plan: UninstallPlan) {
        let trashed = report.trashedURLs
        let appID = plan.app.id
        if trashed.contains(plan.app.url) {
            apps.removeAll { $0.id == appID }
            plans[appID] = nil
            sizes[appID] = nil
            if selectedApp == appID {
                selectedApp = nil
                self.plan = nil
            }
            return
        }
        var remaining = plan
        remaining.leftovers.removeAll { trashed.contains($0.url) }
        plans[appID] = remaining
        if self.plan?.app.id == appID {
            self.plan = remaining
            leftoverSelection.subtract(trashed)
        }
    }
}
