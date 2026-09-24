import Cleaner
import Foundation
import MacontrolCore
import ScanEngine
@testable import MacontrolUI
import Safety
import SwiftUI
import Testing
import Uninstaller

/// Hardcore mode on every surface, light and dark, at the minimum window and a large one (T-0073 criterion 12).
/// Set MACONTROL_SNAPSHOT_DIR to keep the PNGs.
@Suite struct HardcoreSnapshotTests {
    /// Every screen with the mode on: the checked toolbar box and the banner.
    @Test(arguments: SidebarItem.allCases)
    func everyScreenWithHardcoreModeOn(item: SidebarItem) throws {
        for size in HardcoreModeTests.sizes {
            let model = AppModel.demo(selection: item)
            model.hardcore.isOn = true
            try Snapshot.write(RootView(model: model), "hardcore-\(item.rawValue)-\(Int(size.width))", size: size)
        }
    }

    @Test func theToolbarWithHardcoreModeOff() throws {
        for size in HardcoreModeTests.sizes {
            try Snapshot.write(RootView(model: .demo(selection: .clean)), "hardcore-off-clean-\(Int(size.width))", size: size)
        }
    }

    @Test func theTurnOnModal() throws {
        let hardcore = HardcoreMode()
        hardcore.checkbox = true
        try Snapshot.write(HardcoreModal(hardcore: hardcore), "hardcore-modal", size: CGSize(width: 480, height: 440))
    }

    /// Clean's permanent review: the strip, a trash-only item apart, the Admin notes and the restore-point box.
    @Test func cleanPermanentReview() async throws {
        let model = Self.cleanModel()
        model.selection.insert(Self.safari.url)
        model.adminItems = [DemoCleanup.items[0].url]
        await model.refreshEstimate()
        model.beginReview()
        let review = try #require(model.review)
        try Snapshot.write(CleanReviewSheet(model: model, review: review), "hardcore-clean-review", size: Snapshot.sheetSize)
        model.review?.run.wantsRestorePoint = true
        try Snapshot.write(CleanReviewSheet(model: model, review: review), "hardcore-clean-review-restore-point", size: Snapshot.sheetSize)
        model.review?.run.restorePointProblem = "tmutil could not create a local snapshot"
        try Snapshot.write(CleanReviewSheet(model: model, review: review), "hardcore-clean-restore-point-failed", size: Snapshot.sheetSize)
    }

    /// A permanent result: deleted, partly deleted, sent to the Trash on purpose, refused; the measured space below
    /// half of the estimate, so the snapshot line shows.
    @Test func permanentResult() throws {
        let model = Self.cleanModel()
        model.selection = Set(model.items.filter(\.canClean).prefix(3).map(\.url) + [Self.safari.url])
        model.beginReview()
        let review = try #require(model.review)
        let items = review.items
        let outcomes: [TrashOutcome] = items.enumerated().map { index, item in
            switch index {
            case 0: .deleted(original: item.url)
            case 1: .failed(item.url, message: "Partly deleted. 12 items inside could not be removed; the rest is in the Trash as "
                + "\"\(item.url.lastPathComponent)\". Empty the Trash to finish. First: a/b: Operation not permitted")
            case items.count - 1: .trashed(original: item.url, trashedTo: URL(fileURLWithPath: "/Users/demo/.Trash/History.db"))
            default: .refused(item.url, .identityChanged)
            }
        }
        let report = TrashReport(batch: UUID(), outcomes: outcomes)
        model.apply(report)
        model.review?.report = report
        model.review?.run.freed = 180_000_000
        try Snapshot.write(CleanReviewSheet(model: model, review: review), "hardcore-clean-result", size: Snapshot.sheetSize)
    }

    /// Uninstall with the administrator helper present: selectable Admin rows, then the sheet in each mode.
    @Test(arguments: [DeletionMode.trash, .permanent])
    func uninstallWithTheHelper(mode: DeletionMode) throws {
        let uninstall = UninstallModel.demo()
        uninstall.canUseAdministrator = true
        uninstall.needsAdministrator = { _ in false }
        let admin = try #require(uninstall.plan?.leftovers.first { $0.needsAdministrator })
        uninstall.setChosen(true, admin)
        let app = AppModel(
            selection: .uninstall, fullDiskAccess: .granted, volume: nil, diskMap: .demo(),
            clean: .demo(), uninstall: uninstall, history: .demo()
        )
        app.hardcore.isOn = mode == .permanent
        try Snapshot.write(RootView(model: app), "hardcore-uninstall-admin-\(mode.rawValue)", size: RootView.minimumSize)
        uninstall.beginUninstall()
        try Snapshot.write(UninstallSheet(model: uninstall), "hardcore-uninstall-sheet-\(mode.rawValue)", size: Snapshot.sheetSize)
    }

    @Test func diskMapPermanentReview() throws {
        let model = DiskMapModel.demo()
        model.hardcore.isOn = true
        model.beginReview()
        model.review?.estimate = .measured(ReclaimEstimate(freesNow: 9_400_000_000, sharedElsewhere: 0))
        let review = try #require(model.review)
        try Snapshot.write(ReviewSheet(model: model, review: review), "hardcore-disk-map-review", size: CGSize(width: 560, height: 700))
    }

    /// History at both sizes with the mode off: the permanent and the helper-trashed demo batches.
    @Test func historyWithPermanentAndHelperBatches() throws {
        for size in HardcoreModeTests.sizes {
            try Snapshot.write(RootView(model: .demo(selection: .history)), "history-batches-\(Int(size.width))", size: size)
        }
    }

    /// The demo items plus Safari's history, with the mode on.
    static func cleanModel() -> CleanModel {
        let model = CleanModel(cleaner: nil, trash: nil, engine: nil, items: DemoCleanup.items + [safari])
        model.support = .demo
        model.hardcore.isOn = true
        return model
    }

    /// A trash-only row for the demo: Safari's history goes to the Trash even in hardcore mode (D4).
    static let safari = CleanupItem(
        rule: CleanModelTests.rule(.review), url: URL(fileURLWithPath: "/Users/demo/Library/Safari/History.db"), identity: nil,
        measurement: ItemMeasurement(allocated: 42_000_000, logical: 42_000_000, fileCount: 1, newestModification: nil, isIncomplete: false),
        skipReason: nil
    )
}
