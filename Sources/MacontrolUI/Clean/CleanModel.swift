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
    /// The scan runs in its own task: leaving the screen cancels the view's `.task`, and a cut-short
    /// scan must not pass for a finished one ("Your Mac is tidy") here or on the Overview.
    func scan() async {
        guard let cleaner, !isScanning else { return }
        isScanning = true
        scanError = nil
        items = []
        selection = []
        await Task { await consume(cleaner.scan()) }.value
        isScanning = false
        hasScanned = true
    }

    private func consume(_ stream: AsyncThrowingStream<CleanupItem, any Error>) async {
        do {
            for try await item in stream {
                items.append(item)
                if item.isPreselected { selection.insert(item.url) }
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
            return CleanGroup(category: category, items: items.sorted { $0.measurement.allocated > $1.measurement.allocated })
        }
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
    var estimateKey: Set<URL>? { isScanning ? nil : selection }

    /// Recomputes what the checked items free. Called from `.task(id: estimateKey)`, which cancels stale runs.
    func refreshEstimate() async {
        guard !isScanning else { return }
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
        guard !selected.isEmpty, review == nil, !isScanning else { return }
        let kept = Set(selected.map(\.url).removingNested())
        let listed = selected.filter { kept.contains($0.url) }
        let visible = Set(groups.flatMap(\.items).map(\.url))
        review = CleanReview(
            items: listed,
            nestedCount: selected.count - kept.count,
            hiddenBySearch: listed.filter { !visible.contains($0.url) }.count
        )
    }

    /// Checks the reviewed items again, moves the ones that still pass, then applies each outcome.
    /// The scan can be hours old: an app launched since keeps its cache (F-0015).
    func confirmReview() async {
        guard let pending = review, pending.report == nil, !pending.isWorking else { return }
        review?.isWorking = true
        var toMove = pending.items
        if let cleaner {
            let checked = await cleaner.recheck(pending.items)
            update(with: checked)
            toMove = checked.filter(\.canClean)
            review?.items = checked
            review?.notMoved = Dictionary(
                checked.filter { !$0.canClean }.map { ($0.url, $0.skipReason ?? "It can't be cleaned now") },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let batch = toMove.map(\.trashItem)
        let report = if let trash {
            batch.isEmpty ? TrashReport(batch: UUID(), outcomes: []) : await trash.moveToTrash(batch)
        } else {
            // Demo data: nothing real to move.
            TrashReport(batch: UUID(), outcomes: batch.map { .refused($0.url, .notImplemented) })
        }
        apply(report)
        review?.isWorking = false
        review?.report = report
    }

    /// Puts rechecked items back in the list: fresh sizes and skip reasons, and a held item is unchecked.
    private func update(with checked: [CleanupItem]) {
        let fresh = Dictionary(checked.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        items = items.map { fresh[$0.url] ?? $0 }
        selection.subtract(checked.filter { !$0.canClean }.map(\.url))
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
