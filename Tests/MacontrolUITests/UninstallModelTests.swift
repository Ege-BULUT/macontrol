import Foundation
import MacontrolCore
@testable import MacontrolUI
import os
import Safety
import Testing
import TestSupport
import Uninstaller

@Suite struct UninstallModelTests {
    @Test func appsAreSectionedAppsThenAppleThenMacOS() {
        let model = UninstallModel.demo()
        #expect(model.sections.map(\.kind) == [.thirdParty, .appleAppStore, .builtIn])
        #expect(model.sections.map(\.apps.count).reduce(0, +) == model.apps.count)
    }

    @Test func searchMatchesNameOrBundleID() {
        let model = UninstallModel.demo()
        model.query = "garage"
        #expect(model.sections.flatMap(\.apps).map(\.name) == ["GarageBand"])
        model.query = "com.apple.chess"
        #expect(model.sections.flatMap(\.apps).map(\.name) == ["Chess"])
    }

    /// F-0011, F-0022: only exact identifiers start chosen; exact-name, shared and admin-only items do not.
    @Test func onlyPreselectedLeftoversStartChosen() throws {
        let model = UninstallModel.demo()
        let leftovers = try #require(model.plan?.leftovers)
        #expect(model.leftoverSelection == Set(leftovers.filter(\.isPreselected).map(\.url)))
        let held = leftovers.filter { $0.evidence == .exactName || $0.note != nil || $0.needsAdministrator }
        #expect(held.count == 3)
        #expect(held.allSatisfy { !model.isChosen($0) })
    }

    @Test func adminLeftoversCanNeverBeChosen() throws {
        let model = UninstallModel.demo()
        let leftovers = try #require(model.plan?.leftovers)
        let admin = try #require(leftovers.first { $0.needsAdministrator })
        model.setChosen(true, admin)
        model.toggle(Set(leftovers.map(\.url)))
        #expect(!model.isChosen(admin))
        #expect(model.chosenLeftovers.count == leftovers.count - 1)

        // Even if the selection were corrupted, the batch never carries a root-owned item.
        model.leftoverSelection.insert(admin.url)
        model.beginUninstall()
        #expect(model.confirmation?.rows.contains { $0.url == admin.url } == false)
    }

    @Test func partOfMacOSHasNoUninstall() {
        let model = UninstallModel.demo(showing: .builtIn)
        #expect(model.plan?.app.kind == .builtIn)
        #expect(!model.canUninstall)
        model.beginUninstall()
        #expect(model.confirmation == nil)
    }

    @Test func aBlockedThirdPartyAppHasNoUninstall() async {
        let app = DemoApps.editor
        let model = UninstallModel(uninstaller: nil, apps: [app], engine: nil)
        model.plans[app.url] = UninstallPlan(app: app, appMeasurement: .zero, leftovers: [], blocker: "Owned by root.")
        model.selectedApp = app.id
        await model.loadPlan()
        #expect(model.plan?.blocker == "Owned by root.")
        #expect(!model.canUninstall)
        model.beginUninstall()
        #expect(model.confirmation == nil)
    }

    @Test func everyLeftoverKindGetsASectionInDisplayOrder() throws {
        let leftovers = try #require(UninstallModel.demo().plan?.leftovers)
        let sections = LeftoverEvidence.sections(of: leftovers.reversed())
        #expect(Set(sections) == Set(leftovers.map(\.evidence)))
        #expect(sections == LeftoverEvidence.displayOrder.filter(sections.contains))
    }

    @Test func appleAppsCanBeUninstalled() {
        let model = UninstallModel.demo(showing: .appleAppStore)
        #expect(model.canUninstall)
    }

    @Test func confirmationListsTheBundleThenExactlyTheChosenLeftovers() throws {
        let model = UninstallModel.demo()
        let plan = try #require(model.plan)
        model.beginUninstall()
        let rows = try #require(model.confirmation?.rows)
        #expect(rows.map(\.url) == [plan.app.url] + plan.leftovers.filter(model.isChosen).map(\.url))
        #expect(model.confirmation?.appIsRunning == true)
    }

    /// What the sheet lists is what reaches the Trash (F-0050, F-0069). A recorder stands in for quitting, launchctl
    /// and the Trash, so nothing is quit or moved. It refuses the bundle, which stops the uninstall before the leftovers.
    @Test func uninstallSendsExactlyTheListedItems() async throws {
        let temp = try TemporaryDirectory()
        let recorder = RecordedActions()
        let model = UninstallModel(uninstaller: try Self.sampleUninstaller(temp, actions: recorder.actions), engine: nil)
        try temp.file("home/Library/Logs/com.example.macontrol-probe/log.txt", size: 1_000)
        let plan = try await Self.selectSample(model)
        let kept = try #require(plan.leftovers.first { $0.url.path.contains("/Logs/") })
        model.setChosen(false, kept)

        model.beginUninstall()
        let rows = try #require(model.confirmation?.rows)
        #expect(rows.count == 2 && !rows.contains { $0.url == kept.url })
        await model.confirmUninstall()

        let report = try #require(model.confirmation?.report)
        #expect(report.outcomes.map(\.url) == rows.map(\.url))
        #expect(recorder.batches.withLock { $0 }.map { $0.map(\.url) } == [[plan.app.url]])
        #expect(model.apps.map(\.url) == [plan.app.url])
    }

    /// An update replaced the bundle after the plan was made, so the uninstall stops (changedSincePlan). The model
    /// then reads the app and its leftovers again, and the retry carries the new bundle's identity.
    @Test func aFailedUninstallPlansAgainSoTheRetryUsesFreshIdentities() async throws {
        let temp = try TemporaryDirectory()
        let recorder = RecordedActions()
        let model = UninstallModel(uninstaller: try Self.sampleUninstaller(temp, actions: recorder.actions), engine: nil)
        let stale = try await Self.selectSample(model)

        try FileManager.default.removeItem(at: stale.app.url)  // inside the temp folder
        try Self.bundle(temp, "Probe", "com.example.macontrol-probe")
        try temp.file("home/Library/Logs/com.example.macontrol-probe/log.txt", size: 1_000)
        model.beginUninstall()
        await model.confirmUninstall()

        #expect(model.confirmation?.errorMessage?.contains("changed") == true)
        #expect(recorder.batches.withLock { $0 }.isEmpty)
        let fresh = try #require(model.plan)
        #expect(fresh.app.identity == FileIdentity(url: stale.app.url) && fresh.app.identity != stale.app.identity)
        #expect(fresh.leftovers.count == 2)

        model.confirmation = nil
        model.beginUninstall()
        await model.confirmUninstall()
        #expect(recorder.batches.withLock { $0 }.first?.map(\.expectedIdentity) == [fresh.app.identity])
    }

    /// Scan Again, and every new selection, reads the app's leftovers from disk instead of reusing a plan.
    @Test func reselectingAnAppFindsLeftoversCreatedSince() async throws {
        let temp = try TemporaryDirectory()
        let model = UninstallModel(uninstaller: try Self.sampleUninstaller(temp), engine: nil)
        let app = try await Self.selectSample(model).app
        #expect(model.plan?.leftovers.count == 1)

        try temp.file("home/Library/Logs/com.example.macontrol-probe/log.txt", size: 1_000)
        model.selectedApp = nil
        await model.loadPlan()
        model.selectedApp = app.id
        await model.loadPlan()
        #expect(model.plan?.leftovers.count == 2)

        try temp.file("home/Library/HTTPStorages/com.example.macontrol-probe/cookies", size: 1_000)
        await model.rescan()
        #expect(model.plan?.leftovers.count == 3)
    }

    @Test func eachVisitListsAppsInstalledSince() async throws {
        let temp = try TemporaryDirectory()
        let model = UninstallModel(uninstaller: try Self.sampleUninstaller(temp), engine: nil)
        await model.loadApps()
        #expect(model.apps.count == 1)
        try Self.bundle(temp, "Second", "com.example.macontrol-probe2")
        await model.loadApps()
        #expect(model.apps.map(\.name) == ["Probe", "Second"])
    }

    /// F-0011: a leftover the user unchecked to keep stays unchecked after a visit to another app.
    @Test func switchingAppsKeepsTheUsersLeftoverChoices() async throws {
        let model = UninstallModel.demo()
        let editor = try #require(model.plan)
        let kept = try #require(editor.leftovers.first { $0.isPreselected })
        model.setChosen(false, kept)
        model.selectedApp = DemoApps.garageBand.id
        await model.loadPlan()
        model.selectedApp = editor.app.id
        await model.loadPlan()
        #expect(model.plan?.app.id == editor.app.id)
        #expect(!model.isChosen(kept))
        #expect(model.leftoverSelection == Set(editor.leftovers.filter(\.isPreselected).map(\.url)).subtracting([kept.url]))
    }

    /// The running warning is read when the sheet opens. Finder stands in for an app opened after it was selected;
    /// only its bundle id is borrowed, and nothing is quit.
    @Test func theConfirmationChecksAgainWhetherTheAppIsOpen() async throws {
        let temp = try TemporaryDirectory()
        try Self.bundle(temp, "FinderTwin", "com.apple.finder")
        let model = UninstallModel(uninstaller: try Self.uninstaller(temp, actions: RecordedActions().actions), engine: nil)
        await model.loadApps()
        model.selectedApp = try #require(model.apps.first).id
        await model.loadPlan()
        model.runningBundleIDs = []  // as it was before the user opened the app
        model.beginUninstall()
        #expect(model.confirmation?.appIsRunning == true)
    }

    /// F-0069: the sheet names every background item it stops and every note the plan carries.
    @Test func confirmationListsEveryStepBesidesTheMoves() throws {
        let model = UninstallModel.demo()
        let plan = try #require(model.plan)
        model.beginUninstall()
        #expect(model.confirmation?.notes == [
            "Stops background item com.example.Editor.helper", "Stops background item com.example.Editor.updater",
        ] + plan.notes)

        let agent = try #require(plan.leftovers.first { $0.launchdLabel != nil })
        model.confirmation = nil
        model.setChosen(false, agent)
        model.beginUninstall()
        #expect(model.confirmation?.notes == ["Stops background item com.example.Editor.helper"] + plan.notes)
    }

    @Test func anUninstalledAppLeavesTheList() throws {
        let model = UninstallModel.demo()
        let plan = try #require(model.plan)
        model.apply(TrashReport(batch: UUID(), outcomes: [
            .trashed(original: plan.app.url, trashedTo: URL(fileURLWithPath: "/Users/demo/.Trash/Editor.app")),
        ]), to: plan)
        #expect(!model.apps.contains { $0.id == plan.app.id })
        #expect(model.selectedApp == nil && model.plan == nil)
    }

    @Test func movedLeftoversLeaveThePlanWhenTheAppStays() throws {
        let model = UninstallModel.demo()
        let plan = try #require(model.plan)
        let moved = plan.leftovers[0]
        model.apply(TrashReport(batch: UUID(), outcomes: [
            .refused(plan.app.url, .identityChanged),
            .trashed(original: moved.url, trashedTo: URL(fileURLWithPath: "/Users/demo/.Trash/x")),
        ]), to: plan)
        #expect(model.apps.contains { $0.id == plan.app.id })
        #expect(model.plan?.leftovers.count == plan.leftovers.count - 1)
        #expect(!model.leftoverSelection.contains(moved.url))
    }

    /// Reads a fake app and its cache from temp folders through the real Uninstaller. Nothing is changed.
    @Test func loadsAppsPlansAndSizesFromTheUninstaller() async throws {
        let temp = try TemporaryDirectory()
        let bundle = try temp.directory("Applications/Sample.app/Contents")
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.macontrol-sample", "CFBundleName": "Sample", "CFBundleShortVersionString": "2.1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
        try temp.file("Applications/Sample.app/Contents/MacOS/Sample", size: 30_000)
        try temp.file("home/Library/Caches/com.example.macontrol-sample/data", size: 20_000)
        let model = UninstallModel(uninstaller: try Self.uninstaller(temp))

        await model.loadApps()
        let app = try #require(model.apps.first)
        #expect(model.apps.count == 1 && app.name == "Sample" && app.kind == .thirdParty)
        await model.measureIfNeeded(app)
        #expect((model.sizes[app.url] ?? 0) >= 30_000)

        model.selectedApp = app.id
        await model.loadPlan()
        let cache = temp.url.appendingPathComponent("home/Library/Caches/com.example.macontrol-sample")
        #expect(model.plan?.leftovers.map(\.url.lastPathComponent) == [cache.lastPathComponent])
        #expect(model.leftoverSelection.map(\.lastPathComponent) == [cache.lastPathComponent])
    }

    /// Probe.app with one cache, read through the real Uninstaller. Home, application folder and system root all
    /// live in the temp folder.
    static func sampleUninstaller(_ temp: TemporaryDirectory, actions: UninstallActions? = nil) throws -> Uninstaller {
        try bundle(temp, "Probe", "com.example.macontrol-probe")
        try temp.file("home/Library/Caches/com.example.macontrol-probe/data", size: 2_000)
        return try uninstaller(temp, actions: actions)
    }

    static func uninstaller(_ temp: TemporaryDirectory, actions: UninstallActions? = nil) throws -> Uninstaller {
        Uninstaller(
            home: temp.url.appendingPathComponent("home"), applicationFolders: [temp.url.appendingPathComponent("Applications")],
            systemRoot: try temp.directory("root"), trash: TrashService(journalURL: temp.url.appendingPathComponent("journal.jsonl")),
            actions: actions
        )
    }

    static func selectSample(_ model: UninstallModel) async throws -> UninstallPlan {
        await model.loadApps()
        model.selectedApp = try #require(model.apps.first).id
        await model.loadPlan()
        return try #require(model.plan)
    }

    @discardableResult
    static func bundle(_ temp: TemporaryDirectory, _ name: String, _ id: String) throws -> URL {
        let contents = try temp.directory("Applications/\(name).app/Contents")
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try temp.file("Applications/\(name).app/Contents/MacOS/\(name)", size: 1_000)
        return contents.deletingLastPathComponent()
    }
}

/// Stands in for quitting, launchctl and the Trash: records each batch, refuses it, and changes nothing.
struct RecordedActions {
    let batches = OSAllocatedUnfairLock<[[TrashItem]]>(initialState: [])

    var actions: UninstallActions {
        UninstallActions(
            quit: { _ in true },
            bootout: { _ in },
            moveToTrash: { [batches] items in
                batches.withLock { $0.append(items) }
                return TrashReport(batch: UUID(), outcomes: items.map { .refused($0.url, .notImplemented) })
            }
        )
    }
}
