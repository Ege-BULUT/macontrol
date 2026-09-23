import AppKit
import Cleaner
import Foundation
import MacontrolCore
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

    /// T-0060: a skipped row dims its icon, name and path, never its badge. Dimming the whole row to 0.85
    /// put the Safe badge at 3.9:1, so the skipped row's badge must render exactly like an active row's.
    @Test func skippedRowKeepsItsBadgeUndimmed() throws {
        _ = NSApplication.shared
        let width = 640.0
        // The badge's 64 pt column sits left of the 84 pt size column and 12 pt of spacing.
        func badgeColumn(skip: String?) throws -> [UInt8] {
            let item = CleanupItem(
                rule: DemoCleanup.safari, url: URL(fileURLWithPath: "/Users/demo/Library/Caches/com.apple.Safari"), identity: nil,
                measurement: ItemMeasurement(allocated: 410_000_000, logical: 410_000_000, fileCount: 1200, newestModification: nil, isIncomplete: false),
                // Same line count either way, so the badge sits at the same height.
                skipReason: skip, caution: skip == nil ? "Safari is running" : nil
            )
            let data = try SnapshotRenderer.png(of: CleanRow(item: item, isChecked: .constant(false)).frame(width: width), size: nil)
            let image = try #require(NSBitmapImageRep(data: data))
            let pixels = try #require(image.bitmapData)
            let scale = Double(image.pixelsWide) / width
            let bytesPerPixel = image.bitsPerPixel / 8
            var column: [UInt8] = []
            for y in 0..<image.pixelsHigh {
                let row = pixels + y * image.bytesPerRow
                for x in Int((width - 160) * scale)..<Int((width - 96) * scale) {
                    column.append(contentsOf: UnsafeBufferPointer(start: row + x * bytesPerPixel, count: bytesPerPixel))
                }
            }
            return column
        }
        let active = try badgeColumn(skip: nil)
        let skipped = try badgeColumn(skip: "Safari is running")
        #expect(Set(active).count > 20, "the column holds the badge, not blank background")
        #expect(active.count == skipped.count)
        let changed = zip(active, skipped).filter { abs(Int($0) - Int($1)) > 8 }.count
        #expect(changed == 0, "\(changed) badge channel values differ on the skipped row")
    }

    /// Review round 2, item 3 (F-0050): however many notes a plan carries, the list of items keeps most of the sheet.
    @Test func manyNotesLeaveTheItemListItsRoom() throws {
        let notes = (1...8).map { "Suite runs a background service as root (com.vendor.suite.daemon\($0)). macontrol can't stop it." }
        let rows = (0..<5).map { TrashSheetRow(url: URL(fileURLWithPath: "/Users/demo/Library/Caches/com.vendor.suite.\($0)"), bytes: 1_000_000) }
        let sheet = TrashSheet(
            title: "Uninstall Suite?", message: "Suite and 4 items it left behind move to the Trash.",
            warning: "Suite is open. It will be asked to quit first, so save your work.", notes: notes, rows: rows,
            confirmTitle: "Uninstall", report: nil, isWorking: false, onConfirm: {}, onClose: {}
        )
        let list = try #require(Snapshot.largestScrollView(in: sheet, size: Snapshot.sheetSize))
        #expect(list.height > Snapshot.sheetSize.height / 2, "the item list got \(list.height) pt")
        try Snapshot.write(sheet, "trash-sheet-many-notes", size: Snapshot.sheetSize)
    }
}

enum Snapshot {
    static let sheetSize = CGSize(width: 640, height: 540)

    /// Lays `view` out in an off-screen window and returns the frame of its tallest scroll view (a List).
    static func largestScrollView(in view: some View, size: CGSize) -> CGRect? {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func scrollViews(in view: NSView) -> [NSScrollView] {
            if let scrollView = view as? NSScrollView { return [scrollView] }
            return view.subviews.flatMap(scrollViews)
        }
        return scrollViews(in: window.contentView!).map(\.frame).max { $0.height < $1.height }
    }

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
