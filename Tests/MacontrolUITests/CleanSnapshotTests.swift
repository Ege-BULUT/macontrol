import AppKit
import Foundation
@testable import MacontrolUI
import Safety
import SwiftUI
import Testing

/// Renders the Clean screen, its review sheet and the outcomes, light and dark.
/// Set MACONTROL_SNAPSHOT_DIR to keep the PNGs for review.
@Suite struct CleanSnapshotTests {
    @Test func cleanScreenRenders() throws {
        try Snapshot.write(RootView(model: .demo(selection: .clean)), "clean")
    }

    @Test func reviewSheetRenders() async throws {
        let model = CleanModel.demo()
        await model.refreshEstimate()
        model.beginReview()
        let review = try #require(model.review)
        try Snapshot.write(CleanReviewSheet(model: model, review: review), "clean-review", size: Snapshot.sheetSize)
    }

    @Test func outcomesAndInTrashRender() throws {
        let model = CleanModel.demo()
        model.beginReview()
        let review = try #require(model.review)
        // A mixed result: everything moved except one item that changed after the scan.
        let report = TrashReport(batch: UUID(), outcomes: review.items.enumerated().map { index, item in
            index == 1
                ? .refused(item.url, .identityChanged)
                : .trashed(original: item.url, trashedTo: URL(fileURLWithPath: "/Users/demo/.Trash").appendingPathComponent(item.name))
        })
        model.apply(report)
        model.review?.report = report
        try Snapshot.write(CleanReviewSheet(model: model, review: review), "clean-outcomes", size: Snapshot.sheetSize)

        // A presented sheet dims its window, so close it before rendering the screen.
        model.review = nil

        let app = AppModel(
            selection: .clean, fullDiskAccess: .granted, volume: nil, diskMap: .demo(),
            clean: model, uninstall: .demo(), history: .demo()
        )
        try Snapshot.write(RootView(model: app), "clean-after")
    }
}

enum Snapshot {
    static let sheetSize = CGSize(width: 640, height: 540)

    /// Renders `view` light and dark, checks the PNGs, and keeps them when MACONTROL_SNAPSHOT_DIR is set.
    static func write(_ view: some View, _ name: String, size: CGSize = SnapshotRenderer.windowSize) throws {
        _ = NSApplication.shared
        let folder = ProcessInfo.processInfo.environment["MACONTROL_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
        for dark in [false, true] {
            let data = try SnapshotRenderer.png(of: view, dark: dark, size: size)
            #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "\(name) is not a PNG")
            #expect(data.count > 20_000, "\(name) rendered almost nothing")
            if let folder {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
