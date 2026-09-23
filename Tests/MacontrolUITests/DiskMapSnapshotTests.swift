import AppKit
import Foundation
import MacontrolCore
@testable import MacontrolUI
import Testing

/// Renders the map in both styles and the review sheet, light and dark, with demo data.
/// Set MACONTROL_SNAPSHOT_DIR=<folder> to keep the PNGs.
@Suite(.serialized) struct DiskMapSnapshotTests {
    private func write(_ data: Data, _ name: String) throws {
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "\(name)")
        #expect(data.count > 20_000, "\(name) rendered almost nothing")
        guard let folder = ProcessInfo.processInfo.environment["MACONTROL_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    @Test(arguments: MapStyle.allCases)
    func mapRenders(style: MapStyle) async throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let app = AppModel.demo(selection: .diskMap)
            app.diskMap.style = style
            // A test body runs inside a main-queue job, so the view's own layout task cannot finish
            // during the render; lay out ahead at about the chart's size (the view scales it to fit).
            await app.diskMap.prepareLayout(app.diskMap.layoutKey(width: 510, height: 470, scale: 2))
            let data = try SnapshotRenderer.png(of: RootView(model: app), dark: dark)
            try write(data, "disk-map-\(style.rawValue)-\(dark ? "dark" : "light")")
        }
    }

    @Test func reviewSheetRenders() throws {
        _ = NSApplication.shared
        let model = DiskMapModel.demo()
        let staged = model.pile.items
        let shared: UInt64 = 3_600_000_000
        let states: [(String, ReviewState, Double)] = [
            ("confirm", ReviewState(items: staged, estimate: .measured(ReclaimEstimate(freesNow: model.pile.totalBytes - shared, sharedElsewhere: shared))), 390),
            ("refused", ReviewState(items: staged, phase: .done(staged.map {
                ReviewOutcome(name: $0.name, path: $0.url.path, bytes: $0.bytes, status: .notMoved(DiskMapText.refusal(.notImplemented)))
            })), 320),
        ]
        for (name, review, height) in states {
            for dark in [false, true] {
                let data = try SnapshotRenderer.png(of: ReviewSheet(model: model, review: review), dark: dark, size: CGSize(width: 560, height: height))
                try write(data, "disk-map-review-\(name)-\(dark ? "dark" : "light")")
            }
        }
    }
}
