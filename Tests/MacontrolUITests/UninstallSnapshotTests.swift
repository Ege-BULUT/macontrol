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

    @Test func confirmationSheetRenders() throws {
        let model = UninstallModel.demo()
        model.beginUninstall()
        #expect(model.confirmation != nil)
        try Snapshot.write(UninstallSheet(model: model), "uninstall-confirm", size: Snapshot.sheetSize)
    }
}
