import Foundation
import MacontrolCore
@testable import MacontrolUI
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

    /// What the sheet lists is what reaches the Trash (F-0050, F-0069). The paths do not exist and
    /// the identities are wrong, so nothing can move with either the scaffold or the real services.
    @Test func uninstallSendsExactlyTheListedItems() async throws {
        let temp = try TemporaryDirectory()
        let bogus = FileIdentity(device: 0, inode: 1)
        let app = InstalledApp(url: temp.url.appendingPathComponent("Applications/Gone.app"), name: "Gone",
                               bundleIdentifier: "com.example.macontrol-test-gone", version: "1", kind: .thirdParty, identity: bogus)
        let leftovers = ["Caches", "Preferences", "Application Support"].map {
            Leftover(url: temp.url.appendingPathComponent("home/Library/\($0)/com.example.macontrol-test-gone"), identity: bogus,
                     evidence: $0 == "Application Support" ? .exactName : .bundleIdentifier, measurement: .zero,
                     needsAdministrator: false, note: nil)
        }
        let trash = TrashService(journalURL: temp.url.appendingPathComponent("journal.jsonl"))
        let uninstaller = Uninstaller(home: temp.url.appendingPathComponent("home"), applicationFolders: [], trash: trash)
        let model = UninstallModel(uninstaller: uninstaller, apps: [app],
                                   plan: UninstallPlan(app: app, appMeasurement: .zero, leftovers: leftovers, blocker: nil), engine: nil)

        model.beginUninstall()
        let rows = try #require(model.confirmation?.rows)
        #expect(rows.count == 3)
        await model.confirmUninstall()

        let confirmation = try #require(model.confirmation)
        if let report = confirmation.report {
            #expect(report.outcomes.map(\.url) == rows.map(\.url))
            #expect(report.trashedURLs.isEmpty)
        } else {
            #expect(confirmation.errorMessage != nil)
        }
        #expect(model.apps == [app])
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
        let uninstaller = Uninstaller(
            home: temp.url.appendingPathComponent("home"), applicationFolders: [temp.url.appendingPathComponent("Applications")],
            trash: TrashService(journalURL: temp.url.appendingPathComponent("journal.jsonl"))
        )
        let model = UninstallModel(uninstaller: uninstaller)

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
}
