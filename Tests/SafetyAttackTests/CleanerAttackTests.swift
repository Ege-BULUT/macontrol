import Cleaner
import Darwin
import Foundation
import MacontrolCore
import Safety
import Testing

/// The Clean flow as the Clean screen runs it: scan, recheck just before the move, trash what may still be
/// cleaned. A worst-case user checks every item the list lets them check.
@Suite struct CleanerAttackTests {
    let box: Sandbox
    let caches = "home/Library/Caches"
    /// Fixture files cannot be backdated past their ctime, so the cleaner's clock runs a year ahead instead.
    static let clock = Date().addingTimeInterval(365 * 86_400)

    init() throws {
        box = try Sandbox()
    }

    func cleaner(processes: @escaping @Sendable (URL) -> ProcessSnapshot = { _ in ProcessSnapshot(apps: [], openFiles: []) }) -> Cleaner {
        let rule = CleanupRule(
            id: "caches", title: "App caches", category: .appCaches, safety: .safe,
            paths: ["~/Library/Caches/*"], minimumAgeDays: nil, note: "", owners: nil
        )
        return Cleaner(catalog: CleanupCatalog(version: 1, rules: [rule]), home: box.home, processes: processes, now: { Self.clock })
    }

    func scan(_ cleaner: Cleaner) async throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        for try await item in cleaner.scan() { items.append(item) }
        return items
    }

    /// What the Clean screen's Move to Trash does with every cleanable item checked.
    func clean(_ items: [CleanupItem], with cleaner: Cleaner) async -> (checked: [CleanupItem], report: TrashReport) {
        let checked = await cleaner.recheck(items)
        let report = await box.service().moveToTrash(checked.filter(\.canClean).map(\.trashItem))
        return (checked, report)
    }

    func named(_ name: String, in items: [CleanupItem]) -> CleanupItem? {
        items.first { $0.url.lastPathComponent == name }
    }

    /// A cache entry that links to Documents is offered as a link: sized as a link, trashed as a link. The cloud
    /// and CloudKit state a catch-all rule also matches never moves. Undo restores every cleaned item.
    @Test func linksAndProtectedStateInsideCachesStay() async throws {
        try box.file("home/Documents/thesis.docx", size: 4 << 20)
        try FileManager.default.createSymbolicLink(at: box.url("\(caches)/com.example.docs"), withDestinationURL: box.url("home/Documents"))
        try box.file("\(caches)/com.apple.bird/state.db")
        try box.file("\(caches)/CloudKit/records.db")
        try box.file("\(caches)/com.example.plain/blob", size: 1 << 16)
        try box.file("\(caches)/\(HostileNames.shell[0])/blob")
        let cleaner = cleaner()
        let before = box.tree()

        let items = try await scan(cleaner)
        let link = try #require(named("com.example.docs", in: items))
        #expect(link.measurement.allocated < 64 << 10, "a link was sized as its target (\(link.measurement.allocated) B)")
        let (_, report) = await clean(items, with: cleaner)

        let gone = ["com.example.docs", "com.example.plain", HostileNames.shell[0]].map { "\(caches)/\($0)" }
        #expect(Sandbox.difference(box.tree(), Sandbox.expected(before, without: gone)) == [])
        #expect(await box.service().undo(batch: report.batch).allSatisfy { $0.isRestored })
        #expect(Sandbox.difference(box.tree(), before) == [])
    }

    /// Real processes, no fakes: this test holds a file open in one cache, and another cache is named after this
    /// test's own executable. Both are skipped with a reason, and neither moves.
    @Test func aRunningAppsCacheIsNeverCleaned() async throws {
        let open = try box.file("\(caches)/com.example.live/db.sqlite")
        let handle = try FileHandle(forUpdating: open)
        defer { try? handle.close() }
        let running = ProcessInfo.processInfo.processName
        try box.file("\(caches)/\(running)/state")
        try box.file("\(caches)/com.example.idle/blob")
        let cleaner = cleaner(processes: { ProcessSnapshot.current(under: $0) })
        let before = box.tree()

        let (checked, report) = await clean(try await scan(cleaner), with: cleaner)

        let live = try #require(named("com.example.live", in: checked))
        let own = try #require(named(running, in: checked))
        #expect(!live.canClean && !own.canClean)
        #expect(live.skipReason?.hasPrefix("In use by") == true || live.skipReason?.hasPrefix("Could not check") == true, "\(live.skipReason ?? "no reason")")
        #expect(own.skipReason?.hasSuffix("is running") == true || own.skipReason?.hasPrefix("Could not check") == true, "\(own.skipReason ?? "no reason")")
        // The idle cache goes too, unless a process whose files cannot be read holds every item back.
        #expect(report.outcomes.filter(\.isTrashed).map(\.original?.lastPathComponent) == (report.outcomes.isEmpty ? [] : ["com.example.idle"]))
        let idle = report.outcomes.isEmpty ? [] : ["\(caches)/com.example.idle"]
        #expect(Sandbox.difference(box.tree(), Sandbox.expected(before, without: idle)) == [])
    }

    /// The app opens its cache after the scan and before the user presses Move to Trash: the recheck catches it.
    @Test func aCacheOpenedAfterTheScanIsHeldBack() async throws {
        let file = try box.file("\(caches)/com.example.late/db.sqlite")
        let cleaner = cleaner(processes: { ProcessSnapshot.current(under: $0) })
        let items = try await scan(cleaner)
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let before = box.tree()

        let (checked, report) = await clean(items, with: cleaner)

        #expect(named("com.example.late", in: checked)?.canClean == false)
        #expect(report.outcomes.isEmpty)
        #expect(box.tree() == before)
    }

    /// Between the scan and the clean, a cache folder is replaced by a link to Documents. The recheck keeps the
    /// scan's identity, so the Trash refuses it and Documents is untouched.
    @Test func aCacheSwappedForALinkAfterTheScanIsRefused() async throws {
        try box.file("\(caches)/com.example.swap/blob")
        try box.file("home/Documents/thesis.docx")
        let cleaner = cleaner()
        let items = try await scan(cleaner)
        try box.swapForSymlink("\(caches)/com.example.swap", to: box.url("home/Documents"))
        let before = box.tree()

        let (_, report) = await clean(items, with: cleaner)

        #expect(report.outcomes.allSatisfy { !$0.isTrashed })
        #expect(box.tree() == before)
    }

    /// A cache holding a chain past PATH_MAX is measured to the bottom, moves whole and comes back whole.
    @Test func aCacheDeeperThanPathMaxIsMeasuredAndMovedWhole() async throws {
        let chain = try box.deepChain("\(caches)/com.example.deep")
        let cleaner = cleaner()
        let before = box.tree()

        let items = try await scan(cleaner)
        let deep = try #require(named("com.example.deep", in: items))
        #expect(deep.measurement.fileCount == 1 && deep.measurement.allocated >= 4096 && !deep.measurement.isIncomplete)
        let (_, report) = await clean(items, with: cleaner)

        #expect(box.tree()[chain.leaf] == nil && report.outcomes.allSatisfy { $0.isTrashed })
        #expect(await box.service().undo(batch: report.batch).allSatisfy { $0.isRestored })
        #expect(Sandbox.difference(box.tree(), before) == [])
    }
}
