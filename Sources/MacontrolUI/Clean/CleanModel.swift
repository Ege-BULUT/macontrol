import Cleaner
import Foundation
import MacontrolCore
import Observation
import Safety
import ScanEngine

/// What the checked items free. Trashing frees nothing until the Trash is emptied, and clones
/// or hard links elsewhere keep their blocks, so this is never the allocated sum (F-0004, F-0042).
enum SpaceEstimate: Equatable {
    case working
    case freesNow(ReclaimEstimate)
    /// The engine could not answer. Allocated bytes are an upper bound, and are labelled as one.
    case atMost(UInt64)
}

/// The open review sheet: exactly the items that will move, fixed when the sheet opens.
struct CleanReview: Identifiable, RemovalConfirmation {
    let id = UUID()
    /// Rechecked just before the move, so sizes and skip reasons are as fresh as the outcome.
    var items: [CleanupItem]
    /// Checked items inside another checked item; they move with it and are not listed twice.
    let nestedCount: Int
    /// Checked items the search currently hides. The sheet lists them anyway and says so.
    let hiddenBySearch: Int
    var isWorking = false
    var report: TrashReport?
    /// Items the recheck held back, with the reason. They stay listed and are not sent to the Trash.
    var notMoved: [URL: String] = [:]
    /// The mode it opened with, and the rest of hardcore mode's state (DESIGN-debloat section 1.1).
    var run = RemovalRun()
    /// Listed items the administrator helper removes; zero without a launcher.
    var adminCount = 0
}

/// A category section: its items, largest first, filtered by the search.
struct CleanGroup: Identifiable {
    let category: CleanupCategory
    let items: [CleanupItem]
    var id: CleanupCategory { category }
    var allocated: UInt64 { items.reduce(0) { $0 + $1.measurement.allocated } }
    var cleanable: [CleanupItem] { items.filter(\.canClean) }
}

@Observable
public final class CleanModel {
    public private(set) var items: [CleanupItem]
    /// Checked items. Only cleanable items ever enter it; row highlight is separate state in the view.
    public var selection: Set<URL>
    public private(set) var isScanning = false
    private(set) var hasScanned: Bool
    private(set) var scanError: String?
    var query = ""
    private(set) var estimate: SpaceEstimate = .working
    /// Moved to the Trash this session. Their bytes are "In Trash", not freed (F-0042).
    private(set) var inTrash: [CleanupItem] = []
    var review: CleanReview?
    /// The app's one switch; `AppModel` hands every screen the same instance.
    var hardcore = HardcoreMode()
    var support = RemovalSupport()
    /// Items owned by the system, found only when the administrator helper can remove them (DESIGN-debloat 1.4).
    var adminItems: Set<URL> = []
    var needsAdministrator: (URL) -> Bool = { ProtectedPaths.refusal(for: $0) == .needsAdministrator }

    private let cleaner: Cleaner?
    private let trash: TrashService?
    private let engine: ScanEngine?
    /// Removes root-owned items through the helper, one dialog per clean. Nil: v1, they are refused.
    let administrator: PrivilegedLauncher?

    public init(
        cleaner: Cleaner?, trash: TrashService?, engine: ScanEngine? = ScanEngine(), items: [CleanupItem] = [],
        administrator: PrivilegedLauncher? = nil
    ) {
        self.cleaner = cleaner
        self.trash = trash
        self.engine = engine
        self.items = items
        self.administrator = administrator
        self.selection = Set(items.filter(\.isPreselected).map(\.url))
        self.hasScanned = !items.isEmpty
    }

    // MARK: Scanning

    func scanIfNeeded() async {
        if !hasScanned { await scan() }
    }

    /// Streams items in as the cleaner measures them; checkboxes start from `isPreselected` only.
    /// The scan runs in its own task: leaving the screen cancels the view's `.task`, and a cut-short
    /// scan must not pass for a finished one ("Your Mac is tidy") here or on the Overview.
    func scan() async {
        guard let cleaner, !isScanning else { return }
        isScanning = true
        scanError = nil
        items = []
        selection = []
        adminItems = []
        // The last figure belongs to the last selection; the footer must not pair it with the new one.
        estimate = .working
        await Task { await consume(cleaner.scan()) }.value
        isScanning = false
        hasScanned = true
    }

    private func consume(_ stream: AsyncThrowingStream<CleanupItem, any Error>) async {
        do {
            for try await item in stream {
                items.append(item)
                if item.isPreselected { selection.insert(item.url) }
                if administrator != nil && needsAdministrator(item.url) { adminItems.insert(item.url) }
            }
        } catch {
            scanError = error.localizedDescription
        }
    }

    // MARK: Selection

    var groups: [CleanGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let visible = needle.isEmpty ? items : items.filter {
            $0.url.path.localizedCaseInsensitiveContains(needle) || $0.rule.title.localizedCaseInsensitiveContains(needle)
        }
        let byCategory = Dictionary(grouping: visible, by: \.rule.category)
        // Fixed category order, so sections do not jump while results stream in.
        return CleanupCategory.allCases.compactMap { category in
            guard let items = byCategory[category] else { return nil }
            return CleanGroup(category: category, items: items.sorted(by: Self.inScreenOrder))
        }
    }

    /// Category order, then largest first: the list and the review sheet read the same way.
    private static func inScreenOrder(_ a: CleanupItem, _ b: CleanupItem) -> Bool {
        let categories = CleanupCategory.allCases
        let (first, second) = (categories.firstIndex(of: a.rule.category) ?? 0, categories.firstIndex(of: b.rule.category) ?? 0)
        return (first, b.measurement.allocated) < (second, a.measurement.allocated)
    }

    var selectedItems: [CleanupItem] {
        items.filter { $0.canClean && selection.contains($0.url) }
    }

    /// What a clean could take. Manual and skipped items are listed but are not junk found.
    var cleanableBytes: UInt64 { items.filter(\.canClean).reduce(0) { $0 + $1.measurement.allocated } }
    var inTrashBytes: UInt64 { inTrash.reduce(0) { $0 + $1.measurement.allocated } }

    func isChecked(_ item: CleanupItem) -> Bool { selection.contains(item.url) }

    func setChecked(_ checked: Bool, _ item: CleanupItem) {
        guard item.canClean else { return }
        if checked { selection.insert(item.url) } else { selection.remove(item.url) }
    }

    /// Space on highlighted rows: all on if any is off, otherwise all off. Uncleanable rows are ignored.
    func toggle(_ urls: Set<URL>) {
        let targets = items.filter { urls.contains($0.url) && $0.canClean }
        let turnOn = targets.contains { !isChecked($0) }
        for item in targets { setChecked(turnOn, item) }
    }

    func setAll(_ checked: Bool, in group: CleanGroup) {
        for item in group.cleanable { setChecked(checked, item) }
    }

    /// Drives `.task(id:)` for the estimate. Constant while scanning: each streamed-in preselected item
    /// would otherwise start another walk of the whole selection, competing with the scan for the disk.
    /// The mode is part of it: in hardcore mode, items that still go to the Trash (D4) free nothing now.
    /// An open review keeps its own mode, so the View menu's Turn Off does not change the figure its sheet shows.
    var estimateKey: EstimateKey? { isScanning ? nil : EstimateKey(selection: selection, mode: estimateMode) }

    private var estimateMode: DeletionMode { review?.run.mode ?? hardcore.mode }

    struct EstimateKey: Hashable {
        let selection: Set<URL>
        let mode: DeletionMode
    }

    /// Recomputes what the checked items free. Called from `.task(id: estimateKey)`, which cancels stale runs.
    func refreshEstimate() async {
        guard !isScanning else { return }
        let selected = estimateMode == .permanent ? selectedItems.filter { support.trashOnlyReason($0.url) == nil } : selectedItems
        let allocated = selected.reduce(0) { $0 + $1.measurement.allocated }
        guard let engine, cleaner != nil else {
            // Demo data has no files to measure.
            estimate = .freesNow(ReclaimEstimate(freesNow: allocated, sharedElsewhere: 0))
            return
        }
        estimate = .working
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let result = try? await engine.reclaimable(selected.map(\.url))
        guard !Task.isCancelled else { return }
        estimate = result.map(SpaceEstimate.freesNow) ?? .atMost(allocated)
    }

    // MARK: Review and Move to Trash

    func beginReview() {
        let selected = selectedItems.sorted(by: Self.inScreenOrder)
        guard !selected.isEmpty, review == nil, !isScanning else { return }
        let kept = Set(selected.map(\.url).removingNested())
        let listed = selected.filter { kept.contains($0.url) }
        let visible = Set(groups.flatMap(\.items).map(\.url))
        review = CleanReview(
            items: listed,
            nestedCount: selected.count - kept.count,
            hiddenBySearch: listed.filter { !visible.contains($0.url) }.count,
            run: RemovalRun(mode: hardcore.mode, urls: listed.map(\.url), support: support),
            adminCount: listed.count { adminItems.contains($0.url) }
        )
    }

    /// "Delete Permanently" after the restore point failed: go on without one.
    func confirmWithoutRestorePoint() async {
        review?.run.restorePointProblem = nil
        review?.run.goesOnWithoutRestorePoint = true
        await confirmReview()
    }

    /// Checks the reviewed items again, moves the ones that still pass, then applies each outcome.
    /// The scan can be hours old: an app launched since keeps its cache (F-0015).
    func confirmReview() async {
        guard let pending = review, pending.report == nil, !pending.isWorking, pending.run.restorePointProblem == nil else { return }
        // From here on only this review is written to: each await below can outlive its sheet.
        review?.isWorking = true
        defer { review.ifStill(pending.id) { $0.isWorking = false } }
        guard let run = await support.makeRestorePoint(in: self, \.review) else { return }
        var toMove = pending.items
        if let cleaner {
            let checked = await cleaner.recheck(pending.items)
            update(with: checked)
            toMove = checked.filter(\.canClean)
            review.ifStill(pending.id) {
                $0.items = checked
                $0.notMoved = Dictionary(
                    checked.filter { !$0.canClean }.map { ($0.url, $0.skipReason ?? "It can't be cleaned now") },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }
        let batch = toMove.map(\.trashItem)
        // No cleaner means no recheck, so nothing may reach a real Trash either.
        let (report, freed) = await support.measuring(run.mode, batch.map(\.url)) {
            if let trash, cleaner != nil {
                batch.isEmpty ? TrashReport(batch: UUID(), outcomes: [])
                    : await trash.remove(batch, mode: run.mode, administrator: administrator, restorePoint: run.restorePoint)
            } else {
                // Demo data: nothing real to move.
                TrashReport(batch: UUID(), outcomes: batch.map { .refused($0.url, .notImplemented) })
            }
        }
        apply(report)
        review.ifStill(pending.id) {
            $0.run.freed = freed
            $0.report = report
        }
    }

    /// Puts rechecked items back in the list: fresh sizes and skip reasons, and a held item is unchecked.
    private func update(with checked: [CleanupItem]) {
        let fresh = Dictionary(checked.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        items = items.map { fresh[$0.url] ?? $0 }
        selection.subtract(checked.filter { !$0.canClean }.map(\.url))
    }

    /// Trashed rows, and rows inside a trashed folder, leave the list and show under "In Trash", and so do permanent
    /// removals that deleted nothing and left the item whole in the Trash. Deleted rows, and partly deleted ones with
    /// the rest in the Trash, leave the list for good; the sheet's row says what is left to empty.
    func apply(_ report: TrashReport) {
        func rows(under urls: Set<URL>) -> [CleanupItem] {
            let paths = urls.map(\.path)
            return items.filter { item in paths.contains { item.url.path == $0 || item.url.path.hasPrefix($0 + "/") } }
        }
        let trashed = rows(under: report.inTrashURLs)
        let goneURLs = Set(rows(under: report.removedURLs).map(\.url))
        // A cache recreated and trashed again is one row, not two with the same id.
        inTrash.removeAll { goneURLs.contains($0.url) }
        inTrash += trashed
        items.removeAll { goneURLs.contains($0.url) }
        selection.subtract(goneURLs)
    }
}
