import Foundation
@testable import MacontrolUI
import Testing
import Uninstaller

/// Renders Uninstall for a third-party app, an Apple app and an app that is part of macOS,
/// plus the confirmation sheet. Set MACONTROL_SNAPSHOT_DIR to keep the PNGs.
@Suite struct UninstallSnapshotTests {
    @Test(arguments: [AppKind.thirdParty, .appleAppStore, .builtIn])
    func uninstallScreenRenders(kind: AppKind) throws {
        let app = AppModel(
            selection: .uninstall, fullDiskAccess: .granted, volume: nil, diskMap: .demo(),
            clean: .demo(), uninstall: .demo(showing: kind), history: .demo()
        )
        try Snapshot.write(RootView(model: app), "uninstall-\(kind.rawValue)")
    }

    /// A root-owned App Store app: the blocker with Reveal in Finder, no Apple notice, leftover checkboxes off.
    @Test func blockedAppRenders() throws {
        let plan = DemoApps.plans.first { $0.app.id == DemoApps.pages.id }
        let uninstall = UninstallModel(uninstaller: nil, apps: DemoApps.apps, plan: plan, engine: nil)
        let app = AppModel(
            selection: .uninstall, fullDiskAccess: .granted, volume: nil, diskMap: .demo(),
            clean: .demo(), uninstall: uninstall, history: .demo()
        )
        try Snapshot.write(RootView(model: app), "uninstall-blocked")
    }

    /// The filter and sort controls: every app largest first, Apple's apps newest first (the rows show the date),
    /// and a filter with nothing to show for the search.
    @Test(arguments: [
        ("uninstall-all-largest", "all", "largestFirst", ""),
        ("uninstall-system-newest", "system", "newestFirst", ""),
        ("uninstall-system-empty", "system", "nameAscending", "Editor"),
    ])
    func filteredAndSortedListRenders(name: String, filter: String, sort: String, query: String) throws {
        try AppListOrderTests.withScratchDefaults(["uninstallFilter": filter, "uninstallSort": sort]) { defaults in
            let uninstall = UninstallModel.demo()
            uninstall.query = query
            let app = AppModel(
                selection: .uninstall, fullDiskAccess: .granted, volume: nil, diskMap: .demo(),
                clean: .demo(), uninstall: uninstall, history: .demo()
            )
            try Snapshot.write(RootView(model: app).defaultAppStorage(defaults), name)
            #expect(uninstall.filter.rawValue == filter && uninstall.sort.rawValue == sort)
        }
    }

    @Test func confirmationSheetRenders() throws {
        let model = UninstallModel.demo()
        model.beginUninstall()
        #expect(model.confirmation != nil)
        try Snapshot.write(UninstallSheet(model: model), "uninstall-confirm", size: Snapshot.sheetSize)
    }
}
