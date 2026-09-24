import Cleaner
import Foundation
import MacontrolCore
@testable import MacontrolUI
import os
import Safety
import Testing
import TestSupport

@Suite struct CleanModelTests {
    @Test func checkboxesStartFromIsPreselectedOnly() {
        let model = CleanModel.demo()
        #expect(model.selection == Set(model.items.filter(\.isPreselected).map(\.url)))
        #expect(model.items.contains { $0.rule.safety == .review } && model.items.contains { $0.skipReason != nil })
        #expect(model.items.contains { $0.caution != nil && $0.canClean && !model.isChecked($0) })
    }

    /// Manual and skipped items are listed, but the headline counts only what a clean could take.
    @Test func theHeadlineCountsOnlyCleanableItems() {
        let model = CleanModel.demo()
        let cleanable = model.items.filter(\.canClean).reduce(0) { $0 + $1.measurement.allocated }
        #expect(model.cleanableBytes == cleanable)
        #expect(model.items.contains { !$0.canClean && $0.measurement.allocated > 0 })
    }

    @Test func manualAndSkippedItemsCanNeverBeChecked() throws {
        let model = CleanModel.demo()
        let blocked = model.items.filter { !$0.canClean }
        #expect(blocked.contains { $0.rule.safety == .manual } && blocked.contains { $0.skipReason != nil })
        for item in blocked { model.setChecked(true, item) }
        model.toggle(Set(model.items.map(\.url)))
        model.toggle(Set(model.items.map(\.url)))
        #expect(blocked.allSatisfy { !model.selection.contains($0.url) })

        // `selection` is public; even a caller that forces them in cannot get them into a review.
        let cleanable = try #require(model.items.first { $0.canClean })
        model.selection = Set(blocked.map(\.url) + [cleanable.url])
        model.beginReview()
        #expect(model.review?.items.map(\.url) == [cleanable.url])
    }

    @Test func spaceChecksAllHighlightedWhenAnyIsOffThenUnchecksAll() {
        let model = CleanModel.demo()
        let cleanable = Set(model.items.filter(\.canClean).map(\.url))
        model.toggle(cleanable)
        #expect(model.selection == cleanable)
        model.toggle(cleanable)
        #expect(model.selection.isEmpty)
    }

    @Test func reviewListsEveryCheckedItemWithoutTruncation() {
        let rule = Self.rule(.safe)
        let items = (0..<500).map { Self.item(rule, "/Users/demo/Library/Caches/app-\($0)") }
        let model = CleanModel(cleaner: nil, trash: nil, engine: nil, items: items)
        model.beginReview()
        #expect(model.review?.items.map(\.url) == items.map(\.url))
    }

    @Test func reviewNamesTheFolderOnceWhenItsChildIsAlsoChecked() {
        let rule = Self.rule(.safe)
        let model = CleanModel(cleaner: nil, trash: nil, engine: nil, items: [
            Self.item(rule, "/Users/demo/Library/Caches/Editor"),
            Self.item(rule, "/Users/demo/Library/Caches/Editor/fonts"),
            Self.item(rule, "/Users/demo/Library/Caches/EditorHelper"),
        ])
        model.beginReview()
        #expect(model.review?.items.map(\.name) == ["Editor", "EditorHelper"])
        #expect(model.review?.nestedCount == 1)
    }

    /// The count covers the listed rows only: a nested item the search hides is not a hidden row.
    @Test func hiddenBySearchCountsListedRowsOnly() {
        let folder = Self.item(CleanupRule(id: "a", title: "Editor data", category: .appCaches, safety: .safe, paths: [],
                                           minimumAgeDays: nil, note: ""), "/Users/demo/Library/Caches/Editor")
        let inside = Self.item(Self.rule(.safe), "/Users/demo/Library/Caches/Editor/fonts")
        let model = CleanModel(cleaner: nil, trash: nil, engine: nil, items: [folder, inside])
        model.query = "data"
        model.beginReview()
        #expect(model.review?.items.map(\.url) == [folder.url])
        #expect(model.review?.hiddenBySearch == 0)
    }

    @Test func reviewSaysWhenTheSearchHidesCheckedItems() {
        let model = CleanModel.demo()
        model.query = "Homebrew"
        model.beginReview()
        let review = model.review
        #expect(review?.items.count == model.selectedItems.count)
        #expect(review?.hiddenBySearch == model.selectedItems.count - 1)
    }

    /// F-0050: the batch sent to TrashService is exactly the list the sheet showed.
    /// The paths do not exist, so nothing can move with either the scaffold or the real service.
    /// Review round 2, item 10: without a cleaner there is no recheck, so a real Trash gets nothing. The files
    /// live in the temp folder and must still be there.
    @Test func withoutACleanerNothingReachesTheTrash() async throws {
        let temp = try TemporaryDirectory()
        let rule = Self.rule(.safe)
        let files = try (0..<3).map { try temp.file("cache-\($0)", size: 1_000) }
        let items = files.map { Self.item(rule, $0.path) }
        let model = CleanModel(
            cleaner: nil, trash: TrashService(journalURL: temp.url.appendingPathComponent("journal.jsonl")), engine: nil, items: items
        )
        model.beginReview()
        await model.confirmReview()
        let report = try #require(model.review?.report)
        #expect(report.outcomes.map(\.url) == items.map(\.url))
        #expect(report.trashedURLs.isEmpty)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(model.items.count == 3 && model.inTrash.isEmpty)
    }

    /// Review round 2, item 10: the review lists items as the screen does, by category and largest first.
    @Test func reviewRowsFollowTheScreenOrder() {
        func item(_ category: CleanupCategory, _ path: String, _ bytes: UInt64) -> CleanupItem {
            CleanupItem(
                rule: CleanupRule(id: path, title: path, category: category, safety: .safe, paths: [], minimumAgeDays: nil, note: ""),
                url: URL(fileURLWithPath: path), identity: nil,
                measurement: ItemMeasurement(allocated: bytes, logical: bytes, fileCount: 1, newestModification: nil, isIncomplete: false),
                skipReason: nil
            )
        }
        let model = CleanModel(cleaner: nil, trash: nil, engine: nil, items: [
            item(.logs, "/Users/demo/Library/Logs/a", 9_000),
            item(.appCaches, "/Users/demo/Library/Caches/small", 1_000),
            item(.appCaches, "/Users/demo/Library/Caches/large", 5_000),
        ])
        model.beginReview()
        #expect(model.review?.items.map(\.name) == ["large", "small", "a"])
        #expect(model.review?.items.map(\.url) == model.groups.flatMap(\.items).map(\.url))
    }

    /// F-0042: trashed rows leave the list and are counted as "In Trash", not freed.
    @Test func trashedRowsMoveToInTrash() {
        let rule = Self.rule(.safe)
        let folder = Self.item(rule, "/Users/demo/Library/Caches/Editor")
        let inside = Self.item(rule, "/Users/demo/Library/Caches/Editor/fonts")
        let kept = Self.item(rule, "/Users/demo/Library/Caches/Other")
        let model = CleanModel(cleaner: nil, trash: nil, engine: nil, items: [folder, inside, kept])
        model.apply(TrashReport(batch: UUID(), outcomes: [
            .trashed(original: folder.url, trashedTo: URL(fileURLWithPath: "/Users/demo/.Trash/Editor")),
            .refused(kept.url, .identityChanged),
        ]))
        #expect(model.items.map(\.url) == [kept.url])
        #expect(Set(model.inTrash.map(\.url)) == [folder.url, inside.url])
        #expect(model.selection == [kept.url])
        #expect(model.inTrashBytes == folder.measurement.allocated + inside.measurement.allocated)
    }

    /// Review round 2, item 5: a cache recreated and trashed again is one In Trash row, so ids stay unique.
    @Test func aCacheTrashedTwiceIsOneInTrashRow() async throws {
        let temp = try TemporaryDirectory()
        try Self.oldFile(temp, "home/Library/Caches/com.example.a/blob")
        let model = CleanModel(cleaner: Cleaner(catalog: Self.cachesCatalog, home: temp.url.appendingPathComponent("home"), now: Self.clock),
                               trash: nil, engine: nil)
        for _ in 0..<2 {
            await model.scan()
            let cache = try #require(model.items.first)
            // A made-up outcome: nothing moves, so the next scan finds the cache again.
            model.apply(TrashReport(batch: UUID(), outcomes: [.trashed(original: cache.url, trashedTo: temp.url.appendingPathComponent("t"))]))
        }
        #expect(model.inTrash.count == 1)
    }

    /// Review round 2, item 4: Scan Again drops the last estimate instead of pairing it with the new selection.
    @Test func scanningAgainResetsTheEstimate() async throws {
        let temp = try TemporaryDirectory()
        try Self.oldFile(temp, "home/Library/Caches/com.example.a/blob")
        let model = CleanModel(cleaner: Cleaner(catalog: Self.cachesCatalog, home: temp.url.appendingPathComponent("home"), now: Self.clock),
                               trash: nil, engine: nil)
        await model.scan()
        await model.refreshEstimate()
        #expect(model.estimate != .working)
        await model.scan()
        #expect(model.estimate == .working)
    }

    /// F-0015: the trash gets only what passes the in-use guard again at confirm time. An app launched
    /// after the scan keeps its cache, the row shows why, and the sheet lists it as not moved.
    /// `trash: nil` sends the batch to the demo path, so nothing can move.
    @Test func confirmChecksAgainAndLeavesOutACacheWhoseAppStartedSinceTheScan() async throws {
        let temp = try TemporaryDirectory()
        for name in ["com.example.Editor", "com.example.Other"] { try Self.oldFile(temp, "home/Library/Caches/\(name)/blob") }
        let editorIsRunning = OSAllocatedUnfairLock(initialState: false)
        let cleaner = Cleaner(catalog: Self.cachesCatalog, home: temp.url.appendingPathComponent("home"), processes: { [editorIsRunning] _ in
            let editor = RunningApp(bundleIdentifier: "com.example.Editor", bundleName: "Editor", executableName: "Editor")
            return ProcessSnapshot(apps: editorIsRunning.withLock { $0 } ? [editor] : [], openFiles: [])
        }, now: Self.clock)
        let model = CleanModel(cleaner: cleaner, trash: nil, engine: nil)
        await model.scan()
        #expect(model.selectedItems.count == 2)
        model.beginReview()

        editorIsRunning.withLock { $0 = true }
        await model.confirmReview()

        let review = try #require(model.review)
        let report = try #require(review.report)
        #expect(report.outcomes.map(\.url.lastPathComponent) == ["com.example.Other"])
        let editor = try #require(model.items.first { $0.name == "com.example.Editor" })
        #expect(editor.skipReason == "Editor is running" && !model.isChecked(editor))
        #expect(review.notMoved == [editor.url: "Editor is running"])
        #expect(review.items.count == 2)
    }

    /// Leaving the screen cancels the view's `.task`; the scan still finishes, so an empty list never
    /// passes for "Your Mac is tidy".
    @Test func leavingTheScreenMidScanDoesNotCutTheScanShort() async throws {
        let temp = try TemporaryDirectory()
        for name in ["a", "b", "c"] { try temp.file("home/Library/Caches/com.example.\(name)/blob", size: 40_000) }
        let model = CleanModel(cleaner: Cleaner(catalog: Self.cachesCatalog, home: temp.url.appendingPathComponent("home"), now: Self.clock),
                               trash: nil, engine: nil)
        let visit = Task { await model.scanIfNeeded() }
        visit.cancel()
        await visit.value
        #expect(model.items.count == 3 && model.hasScanned)
    }

    /// Preselected items stream in during the scan; each must not start another estimate walk.
    @Test func theEstimateWaitsForTheScanToEnd() async throws {
        let temp = try TemporaryDirectory()
        try Self.oldFile(temp, "home/Library/Caches/com.example.a/blob")
        let model = CleanModel(cleaner: Cleaner(catalog: Self.cachesCatalog, home: temp.url.appendingPathComponent("home"), now: Self.clock),
                               trash: nil, engine: nil)
        let scan = Task { await model.scan() }
        while !model.isScanning { await Task.yield() }
        #expect(model.estimateKey == nil)
        await model.refreshEstimate()
        #expect(model.estimate == .working)
        await scan.value
        #expect(model.estimateKey?.selection == model.selection)
    }

    @Test func scanStreamsARealCatalogAndEstimatesTheSelection() async throws {
        let temp = try TemporaryDirectory()
        for path in ["Library/Caches/com.example.Cache/blob", "Library/Logs/Example/log.txt", "Library/Developer/Xcode/Archives/2026-01-01/app"] {
            try Self.oldFile(temp, "home/\(path)")
        }
        let catalog = CleanupCatalog(version: 1, rules: [
            CleanupRule(id: "caches", title: "Caches", category: .appCaches, safety: .safe, paths: ["~/Library/Caches/*"], minimumAgeDays: nil, note: ""),
            CleanupRule(id: "logs", title: "Logs", category: .logs, safety: .review, paths: ["~/Library/Logs/*"], minimumAgeDays: nil, note: ""),
            CleanupRule(id: "archives", title: "Archives", category: .developer, safety: .manual,
                        paths: ["~/Library/Developer/Xcode/Archives/*"], minimumAgeDays: nil, note: ""),
        ])
        let model = CleanModel(cleaner: Cleaner(catalog: catalog, home: temp.url.appendingPathComponent("home"), now: Self.clock), trash: nil)

        await model.scanIfNeeded()

        #expect(Set(model.items.map(\.name)) == ["com.example.Cache", "Example", "2026-01-01"])
        #expect(model.selection.map(\.lastPathComponent) == ["com.example.Cache"])
        #expect(model.groups.map(\.category) == [.appCaches, .logs, .developer])
        await model.refreshEstimate()
        guard case .freesNow(let estimate) = model.estimate else {
            Issue.record("no estimate: \(model.estimate)")
            return
        }
        #expect(estimate.freesNow >= 40_000)
    }

    @Test func nestedURLsAreDropped() {
        let urls = ["/a/b", "/a/b/c", "/a/bc", "/x/y/z", "/x"].map { URL(fileURLWithPath: $0) }
        #expect(urls.removingNested().map(\.path) == ["/a/b", "/a/bc", "/x"])
    }

    static let cachesCatalog = CleanupCatalog(version: 1, rules: [
        CleanupRule(id: "caches", title: "Caches", category: .appCaches, safety: .safe, paths: ["~/Library/Caches/*"], minimumAgeDays: nil, note: ""),
    ])

    /// The cleaners here read time from this clock, two months ahead. A fixture's ctime is "now" and cannot be
    /// backdated, so moving the clock is what puts every file past the recency guards.
    static let clock: @Sendable () -> Date = { Date(timeIntervalSinceNow: 60 * 86_400) }

    /// A 40 KB file, old by `clock`.
    static func oldFile(_ temp: TemporaryDirectory, _ path: String) throws {
        try temp.file(path, size: 40_000)
    }

    static func rule(_ safety: SafetyLevel) -> CleanupRule {
        CleanupRule(id: "test", title: "Test", category: .appCaches, safety: safety, paths: [], minimumAgeDays: nil, note: "")
    }

    static func item(_ rule: CleanupRule, _ path: String) -> CleanupItem {
        CleanupItem(
            rule: rule, url: URL(fileURLWithPath: path), identity: nil,
            measurement: ItemMeasurement(allocated: 4_096, logical: 4_096, fileCount: 1, newestModification: nil, isIncomplete: false),
            skipReason: nil
        )
    }
}
