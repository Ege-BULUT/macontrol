import AppKit
import Foundation
import MacontrolCore
@testable import MacontrolUI
import ScanEngine
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

    /// T-0063: a scan shows the top of the map as it fills in, with a bar against the space it should reach.
    @Test(arguments: MapStyle.allCases)
    func scanningStateRenders(style: MapStyle) throws {
        _ = NSApplication.shared
        let demo = ScanTree.demo()
        var preview = ScanTree(rootURL: demo.rootURL, rootIdentity: demo.identity(of: ScanTree.root))
        for (offset, child) in demo.children(of: ScanTree.root).enumerated() {
            // Part-way: each top-level item has been read to a different extent.
            preview.addChild(
                of: ScanTree.root, name: demo.name(of: child), flags: demo.flags(of: child),
                allocated: demo.allocatedSize(of: child) / UInt64(offset % 3 + 1), logical: 0, identity: demo.identity(of: child)
            )
        }
        preview.finalizeTotals()
        for (suffix, size) in [("", SnapshotRenderer.windowSize), ("-small", CGSize(width: 900, height: 600))] {
            for dark in [false, true] {
                let app = AppModel.demo(selection: .diskMap)
                app.diskMap.style = style
                let generation = app.diskMap.beginScan()
                app.diskMap.expectedTotal = (demo.allocatedSize(of: ScanTree.root), true)
                let path = "/Users/demo/Library/Application Support/Steam/steamapps/common"
                app.diskMap.receive(.progress(ScanProgress(filesVisited: 48_210, bytesVisited: preview.allocatedSize(of: ScanTree.root), currentPath: path)), generation: generation)
                app.diskMap.receive(.preview(preview), generation: generation)
                let data = try SnapshotRenderer.png(of: RootView(model: app), dark: dark, size: size)
                try write(data, "disk-map-scanning-\(style.rawValue)\(suffix)-\(dark ? "dark" : "light")")
            }
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
