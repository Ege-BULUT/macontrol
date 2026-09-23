import Cleaner
import Darwin
import Foundation
import os
import Testing
import TestSupport

/// Scans against a `TemporaryDirectory` standing in for home. Nothing here moves or deletes a file.
@Suite struct CleanerScanTests {
    let home: TemporaryDirectory

    init() throws {
        home = try TemporaryDirectory()
    }

    func rule(_ id: String, _ paths: [String], safety: SafetyLevel = .safe, minimumAgeDays: Int? = nil, owners: [String]? = nil) -> CleanupRule {
        CleanupRule(id: id, title: id, category: .appCaches, safety: safety, paths: paths, minimumAgeDays: minimumAgeDays, note: "", owners: owners)
    }

    func scan(_ rules: [CleanupRule], processes: ProcessSnapshot = ProcessSnapshot(apps: [], openFiles: [])) async throws -> [CleanupItem] {
        try await scan(with: Cleaner(catalog: CleanupCatalog(version: 1, rules: rules), home: home.url, processes: { _ in processes }))
    }

    func scan(with cleaner: Cleaner) async throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        for try await item in cleaner.scan() { items.append(item) }
        return items.sorted { $0.url.path < $1.url.path }
    }

    func age(_ path: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: home.url.appendingPathComponent(path).path)
    }

    /// F-0025: every glob match becomes its own concrete item, so what is sized is exactly what gets trashed.
    @Test func globMatchesBecomeConcreteMeasuredTrashItems() async throws {
        try home.file("Library/Caches/com.example.A/blob", size: 5000)
        try home.file("Library/Caches/com.example.B/blob", size: 10_000)
        try age("Library/Caches/com.example.A/blob", days: 2)
        try age("Library/Caches/com.example.B/blob", days: 2)

        let items = try await scan([rule("caches", ["~/Library/Caches/*"])])

        #expect(items.map(\.url.lastPathComponent) == ["com.example.A", "com.example.B"])
        #expect(items.map(\.trashItem.url) == items.map(\.url))
        #expect(items.allSatisfy { $0.trashItem.expectedIdentity != nil && $0.isPreselected })
        #expect(items.map(\.measurement.allocated) == [8192, 12_288])
    }

    @Test func specificRuleWinsOverTheCatchAllThatContainsIt() async throws {
        try home.file("Library/Caches/Google/Chrome/Cache/data", size: 100)
        try home.file("Library/Caches/Homebrew/downloads/x.tar.gz", size: 100)
        try home.file("Library/Caches/Homebrew/api/formula.json", size: 100)
        try home.file("Library/Caches/pip/wheel", size: 100)
        let rules = [
            rule("chrome", ["~/Library/Caches/Google/Chrome"]),
            rule("brew", ["~/Library/Caches/Homebrew/downloads"]),
            rule("pip", ["~/Library/Caches/pip"], safety: .review),
            rule("caches", ["~/Library/Caches/*"]),
        ]
        for path in ["Google/Chrome/Cache/data", "Homebrew/downloads/x.tar.gz", "Homebrew/api/formula.json", "pip/wheel"] {
            try age("Library/Caches/" + path, days: 2)
        }

        let items = try await scan(rules)

        #expect(items.map { "\($0.rule.id):\($0.url.lastPathComponent)" } == ["chrome:Chrome", "brew:downloads", "pip:pip"])
    }

    @Test func rulesThatFailValidationNeverExpand() async throws {
        try home.file("Documents/thesis/draft.txt", size: 100)
        try home.file("Library/Application Support/App/data", size: 100)

        let cleaner = Cleaner(
            catalog: CleanupCatalog(version: 1, rules: [rule("docs", ["~/Documents/thesis/*"]), rule("support", ["~/Library/Application Support/*"])]),
            home: home.url
        )
        var items: [CleanupItem] = []
        for try await item in cleaner.scan() { items.append(item) }

        #expect(cleaner.catalog.rules.isEmpty)
        #expect(items.isEmpty)
    }

    @Test func symlinkAbovePatternIsRefused() async throws {
        try home.file("Documents/work/report.txt", size: 100)
        try home.directory("Library")
        try home.symlink("Library/Caches", to: home.url.appendingPathComponent("Documents/work").path)

        #expect(try await scan([rule("caches", ["~/Library/Caches/*"])]).isEmpty)
    }

    @Test func runningAppAndRecentChangesAreSkippedWithReasons() async throws {
        try home.file("Library/Caches/com.example.Editor/index", size: 100)
        try home.file("Library/Caches/com.example.Fresh/tile", size: 100)
        try home.file("Library/Caches/com.example.Old/tile", size: 100)
        try age("Library/Caches/com.example.Editor/index", days: 2)
        try age("Library/Caches/com.example.Old/tile", days: 2)
        let editor = RunningApp(bundleIdentifier: "com.example.Editor", bundleName: "Editor", executableName: "Editor")

        let items = try await scan([rule("caches", ["~/Library/Caches/*"])], processes: ProcessSnapshot(apps: [editor], openFiles: []))

        #expect(items.map(\.url.lastPathComponent) == ["com.example.Editor", "com.example.Fresh", "com.example.Old"])
        #expect(items.map(\.skipReason) == ["Editor is running", "Changed in the last 10 minutes", nil])
        #expect(items.map(\.isPreselected) == [false, false, true])
    }

    /// The real libproc snapshot sees this test process holding a file open inside the cache.
    @Test func fileHeldOpenByARunningProcessIsSkipped() async throws {
        let open = try home.file("Library/Caches/Live/store.db", size: 100)
        try home.file("Library/Caches/Idle/store.db", size: 100)
        try age("Library/Caches/Live/store.db", days: 2)
        try age("Library/Caches/Idle/store.db", days: 2)
        let handle = try FileHandle(forReadingFrom: open)
        defer { try? handle.close() }

        let items = try await scan(with: Cleaner(catalog: CleanupCatalog(version: 1, rules: [rule("caches", ["~/Library/Caches/*"])]), home: home.url))
        let reasons = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0.skipReason) })

        #expect(reasons["Idle"] == .some(nil))
        #expect(reasons["Live"]??.hasPrefix("In use by ") == true)
    }

    @Test func minimumAgeDaysSkipsRecentLogs() async throws {
        try home.file("Library/Logs/Recent/today.log", size: 100)
        try home.file("Library/Logs/Stale/old.log", size: 100)
        try age("Library/Logs/Recent/today.log", days: 2)
        try age("Library/Logs/Stale/old.log", days: 30)

        let items = try await scan([rule("logs", ["~/Library/Logs/*"], minimumAgeDays: 7)])

        #expect(items.map(\.skipReason) == ["Changed in the last 7 days", nil])
    }

    @Test func manualItemsAreSizedButNeverCleanable() async throws {
        try home.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", size: 100)
        try age("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", days: 90)

        let items = try await scan([rule("archives", ["~/Library/Developer/Xcode/Archives/*"], safety: .manual)])

        #expect(items.count == 1)
        #expect(items.allSatisfy { !$0.isPreselected && !$0.canClean && $0.measurement.allocated > 0 })
    }

    /// F-0065: every match is measured to the end, however many there are, with no time budget cutting any short.
    @Test func manyMatchesAreAllMeasured() async throws {
        for index in 0..<40 {
            try home.file("Library/Caches/app\(index)/data", size: 4096)
            try age("Library/Caches/app\(index)/data", days: 2)
        }

        let items = try await scan([rule("caches", ["~/Library/Caches/*"])])

        #expect(items.count == 40)
        #expect(items.allSatisfy { $0.measurement.allocated == 4096 && !$0.measurement.isIncomplete && $0.skipReason == nil })
    }

    /// F-0015, Mole #1607 replayed (review probe1): Gemini runs, its dotless 4 KB cache is idle and
    /// not open. Nothing ties the folder to Gemini, so it is listed but never preselected.
    @Test func unidentifiedCacheIsNotPreselectedWhileItsAppRuns() async throws {
        try home.file("Library/Caches/GIPPseudonymousID/store", size: 4096)
        try age("Library/Caches/GIPPseudonymousID/store", days: 2)
        let gemini = RunningApp(bundleIdentifier: "com.google.GeminiMacOS", bundleName: "Gemini", executableName: "Gemini")

        let items = try await scan([rule("caches", ["~/Library/Caches/*"])], processes: ProcessSnapshot(apps: [gemini], openFiles: []))

        #expect(items.count == 1)
        #expect(items.allSatisfy { !$0.isPreselected && $0.canClean && $0.caution == "Cache of an unidentified app" })
    }

    /// Review probe2: a write inside an unreadable folder is invisible to the 10-minute check, so the
    /// item starts unselected. It stays cleanable: an incomplete size never locks an item out (F-0065).
    @Test func partlyUnreadableItemIsNotPreselected() async throws {
        try home.file("Library/Caches/com.example.App/old", size: 100)
        try home.file("Library/Caches/com.example.App/locked/fresh", size: 100)
        try age("Library/Caches/com.example.App/old", days: 2)
        let locked = home.url.appendingPathComponent("Library/Caches/com.example.App/locked").path
        chmod(locked, 0o000)
        defer { chmod(locked, 0o755) }

        let items = try await scan([rule("caches", ["~/Library/Caches/*"])])

        #expect(items.count == 1)
        #expect(items.allSatisfy { $0.measurement.isIncomplete && !$0.isPreselected && $0.canClean && $0.caution == "Some contents could not be read" })
    }

    /// F-0015 "after": the guard runs again right before the trash, with what runs and changed then.
    @Test func recheckCatchesAppsLaunchedAndWritesMadeAfterTheScan() async throws {
        try home.file("Library/Caches/com.example.Editor/index", size: 100)
        try home.file("Library/Caches/com.example.Viewer/tile", size: 100)
        try home.file("Library/Caches/com.example.Gone/tile", size: 100)
        try home.file("Library/Caches/com.example.Idle/tile", size: 100)
        for name in ["Editor/index", "Viewer/tile", "Gone/tile", "Idle/tile"] { try age("Library/Caches/com.example." + name, days: 2) }
        let running = OSAllocatedUnfairLock(initialState: ProcessSnapshot(apps: [], openFiles: []))
        let cleaner = Cleaner(
            catalog: CleanupCatalog(version: 1, rules: [rule("caches", ["~/Library/Caches/*"])]), home: home.url,
            processes: { _ in running.withLock { $0 } }
        )
        let scanned = try await scan(with: cleaner)
        #expect(scanned.allSatisfy { $0.isPreselected })

        let editor = RunningApp(bundleIdentifier: "com.example.Editor", bundleName: "Editor", executableName: "Editor")
        running.withLock { $0 = ProcessSnapshot(apps: [editor], openFiles: []) }
        try home.file("Library/Caches/com.example.Viewer/new-tile", size: 100)
        try FileManager.default.removeItem(at: home.url.appendingPathComponent("Library/Caches/com.example.Gone"))
        let rechecked = await cleaner.recheck(scanned)

        #expect(rechecked.map(\.url) == scanned.map(\.url))
        #expect(rechecked.map(\.skipReason) == ["Editor is running", "No longer there", nil, "Changed in the last 10 minutes"])
        #expect(rechecked.map(\.identity) == scanned.map(\.identity))
    }

    /// Review probe4: APFS is case-insensitive, so `Caches/google/chrome` on disk is the Chrome rule's
    /// folder. It must keep that rule, not fall to the catch-all as `google`.
    @Test func ruleMatchesItsFolderWhateverTheCase() async throws {
        try home.file("Library/Caches/google/chrome/data", size: 100)
        try age("Library/Caches/google/chrome/data", days: 2)
        // A case-sensitive volume has no `Google` folder here, and nothing to prove.
        guard FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Library/Caches/GOOGLE").path) else { return }

        let items = try await scan([rule("chrome", ["~/Library/Caches/Google/Chrome"]), rule("caches", ["~/Library/Caches/*"])])

        #expect(items.map { "\($0.rule.id):\($0.url.path.dropFirst(home.url.path.count))" } == ["chrome:/Library/Caches/google/chrome"])
    }

    /// Only a real `folder/` prefix is containment: `App 2` and `App-x` sort around `App/` and stay,
    /// and `Tool` is not inside `Tool2` (review probe5).
    @Test func overlapIsDecidedByWholeFolders() async throws {
        for name in ["com.x.App/sub/data", "com.x.App 2/data", "com.x.App-x/data", "com.x.App.b/data", "com.x.Tool/data", "com.x.Tool2/data"] {
            try home.file("Library/Caches/" + name, size: 100)
            try age("Library/Caches/" + name, days: 2)
        }

        let items = try await scan([rule("app", ["~/Library/Caches/com.x.App/sub"]), rule("caches", ["~/Library/Caches/*"])])

        #expect(items.map { "\($0.rule.id):\($0.url.lastPathComponent)" } == [
            "caches:com.x.App 2", "caches:com.x.App-x", "caches:com.x.App.b", "app:sub", "caches:com.x.Tool", "caches:com.x.Tool2",
        ])
    }
}
