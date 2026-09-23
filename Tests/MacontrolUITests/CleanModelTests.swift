import Cleaner
import Foundation
import MacontrolCore
@testable import MacontrolUI
import Safety
import Testing
import TestSupport

@Suite struct CleanModelTests {
    @Test func checkboxesStartFromIsPreselectedOnly() {
        let model = CleanModel.demo()
        #expect(model.selection == Set(model.items.filter(\.isPreselected).map(\.url)))
        #expect(model.items.contains { $0.rule.safety == .review } && model.items.contains { $0.skipReason != nil })
    }

    @Test func manualAndSkippedItemsCanNeverBeChecked() throws {
        let model = CleanModel.demo()
        let blocked = model.items.filter { !$0.isCleanable }
        #expect(blocked.contains { $0.rule.safety == .manual } && blocked.contains { $0.skipReason != nil })
        for item in blocked { model.setChecked(true, item) }
        model.toggle(Set(model.items.map(\.url)))
        model.toggle(Set(model.items.map(\.url)))
        #expect(blocked.allSatisfy { !model.selection.contains($0.url) })

        // `selection` is public; even a caller that forces them in cannot get them into a review.
        let cleanable = try #require(model.items.first { $0.isCleanable })
        model.selection = Set(blocked.map(\.url) + [cleanable.url])
        model.beginReview()
        #expect(model.review?.items.map(\.url) == [cleanable.url])
    }

    @Test func spaceChecksAllHighlightedWhenAnyIsOffThenUnchecksAll() {
        let model = CleanModel.demo()
        let cleanable = Set(model.items.filter(\.isCleanable).map(\.url))
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
    @Test func theTrashReceivesExactlyTheReviewedItems() async throws {
        let temp = try TemporaryDirectory()
        let rule = Self.rule(.safe)
        let items = (0..<3).map { Self.item(rule, temp.url.appendingPathComponent("missing-\($0)").path) }
        let model = CleanModel(
            cleaner: nil, trash: TrashService(journalURL: temp.url.appendingPathComponent("journal.jsonl")), engine: nil, items: items
        )
        model.beginReview()
        await model.confirmReview()
        let report = try #require(model.review?.report)
        #expect(report.outcomes.map(\.url) == items.map(\.url))
        #expect(report.trashedURLs.isEmpty)
        #expect(model.items.count == 3 && model.inTrash.isEmpty)
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

    @Test func scanStreamsARealCatalogAndEstimatesTheSelection() async throws {
        let temp = try TemporaryDirectory()
        let old = Date(timeIntervalSinceNow: -30 * 86_400)
        for path in ["Library/Caches/com.example.Cache/blob", "Library/Logs/Example/log.txt", "Library/Developer/Xcode/Archives/2026-01-01/app"] {
            let file = try temp.file("home/\(path)", size: 40_000)
            var url = file
            while url.path != temp.url.path {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
                url.deleteLastPathComponent()
            }
        }
        let catalog = CleanupCatalog(version: 1, rules: [
            CleanupRule(id: "caches", title: "Caches", category: .appCaches, safety: .safe, paths: ["~/Library/Caches/*"], minimumAgeDays: nil, note: ""),
            CleanupRule(id: "logs", title: "Logs", category: .logs, safety: .review, paths: ["~/Library/Logs/*"], minimumAgeDays: nil, note: ""),
            CleanupRule(id: "archives", title: "Archives", category: .developer, safety: .manual,
                        paths: ["~/Library/Developer/Xcode/Archives/*"], minimumAgeDays: nil, note: ""),
        ])
        let model = CleanModel(cleaner: Cleaner(catalog: catalog, home: temp.url.appendingPathComponent("home")), trash: nil)

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
