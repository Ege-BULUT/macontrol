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
struct CleanReview: Identifiable {
    let id = UUID()
    let items: [CleanupItem]
    /// Checked items inside another checked item; they move with it and are not listed twice.
    let nestedCount: Int
    /// Checked items the search currently hides. The sheet lists them anyway and says so.
    let hiddenBySearch: Int
    var isWorking = false
    var report: TrashReport?
}

/// A category section: its items, largest first, filtered by the search.
struct CleanGroup: Identifiable {
    let category: CleanupCategory
    let items: [CleanupItem]
    var id: CleanupCategory { category }
    var allocated: UInt64 { items.reduce(0) { $0 + $1.measurement.allocated } }
    var cleanable: [CleanupItem] { items.filter(\.isCleanable) }
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

    private let cleaner: Cleaner?
    private let trash: TrashService?
    private let engine: ScanEngine?

    public init(cleaner: Cleaner?, trash: TrashService?, engine: ScanEngine? = ScanEngine(), items: [CleanupItem] = []) {
        self.cleaner = cleaner
        self.trash = trash
        self.engine = engine
        self.items = items
        self.selection = Set(items.filter(\.isPreselected).map(\.url))
        self.hasScanned = !items.isEmpty
    }

    // MARK: Scanning

    func scanIfNeeded() async {
        if !hasScanned { await scan() }
    }

    /// Streams items in as the cleaner measures them; checkboxes start from `isPreselected` only.
    func scan() async {
        guard let cleaner, !isScanning else { return }
        isScanning = true
        scanError = nil
        items = []
        selection = []
        defer {
            isScanning = false
            hasScanned = true
        }
        do {
            for try await item in cleaner.scan() {
                items.append(item)
                if item.isPreselected { selection.insert(item.url) }
            }
        } catch is CancellationError {
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
            return CleanGroup(category: category, items: items.sorted { $0.measurement.allocated > $1.measurement.allocated })
        }
    }

    var selectedItems: [CleanupItem] {
        items.filter { $0.isCleanable && selection.contains($0.url) }
    }

    var foundBytes: UInt64 { items.reduce(0) { $0 + $1.measurement.allocated } }
    var inTrashBytes: UInt64 { inTrash.reduce(0) { $0 + $1.measurement.allocated } }

    func isChecked(_ item: CleanupItem) -> Bool { selection.contains(item.url) }

    func setChecked(_ checked: Bool, _ item: CleanupItem) {
        guard item.isCleanable else { return }
        if checked { selection.insert(item.url) } else { selection.remove(item.url) }
    }

    /// Space on highlighted rows: all on if any is off, otherwise all off. Uncleanable rows are ignored.
    func toggle(_ urls: Set<URL>) {
        let targets = items.filter { urls.contains($0.url) && $0.isCleanable }
        let turnOn = targets.contains { !isChecked($0) }
        for item in targets { setChecked(turnOn, item) }
    }

    func setAll(_ checked: Bool, in group: CleanGroup) {
        for item in group.cleanable { setChecked(checked, item) }
    }

    /// Recomputes what the checked items free. Called from `.task(id: selection)`, which cancels stale runs.
    func refreshEstimate() async {
        let selected = selectedItems
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
        let selected = selectedItems
        guard !selected.isEmpty, review == nil else { return }
        let kept = Set(selected.map(\.url).removingNested())
        let visible = Set(groups.flatMap(\.items).map(\.url))
        review = CleanReview(
            items: selected.filter { kept.contains($0.url) },
            nestedCount: selected.count - kept.count,
            hiddenBySearch: selected.filter { !visible.contains($0.url) }.count
        )
    }

    /// Moves exactly the reviewed items, then applies each outcome.
    func confirmReview() async {
        guard let pending = review, pending.report == nil, !pending.isWorking else { return }
        review?.isWorking = true
        let batch = pending.items.map(\.trashItem)
        let report = if let trash {
            await trash.moveToTrash(batch)
        } else {
            // Demo data: nothing real to move.
            TrashReport(batch: UUID(), outcomes: batch.map { .refused($0.url, .notImplemented) })
        }
        apply(report)
        review?.isWorking = false
        review?.report = report
    }

    /// Trashed rows, and rows inside a trashed folder, leave the list and show under "In Trash".
    func apply(_ report: TrashReport) {
        let trashed = report.trashedURLs.map(\.path)
        let gone = items.filter { item in trashed.contains { item.url.path == $0 || item.url.path.hasPrefix($0 + "/") } }
        let goneURLs = Set(gone.map(\.url))
        inTrash += gone
        items.removeAll { goneURLs.contains($0.url) }
        selection.subtract(goneURLs)
    }
}
