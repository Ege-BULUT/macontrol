import Foundation
import MacontrolCore
import Safety

/// The review sheet between the Discard Pile and the Trash, or a permanent delete in hardcore mode.
struct ReviewState: RemovalConfirmation {
    enum Estimate: Equatable {
        case measuring
        case measured(ReclaimEstimate)
        case unavailable
    }

    enum Phase: Equatable {
        case confirm
        case moving
        case done([ReviewOutcome])
    }

    let id = UUID()
    let items: [StagedItem]
    var estimate: Estimate = .measuring
    var phase: Phase = .confirm
    /// The user agreed that iCloud items go from every device.
    var cloudConfirmed = false
    /// The mode it opened with, and the rest of hardcore mode's state (DESIGN-debloat section 1.1).
    var run = RemovalRun()

    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    var isIncomplete: Bool { items.contains(where: \.isIncomplete) }
    var cloudItemCount: Int { items.count(where: \.isInCloud) }
    var canConfirm: Bool { phase == .confirm && (cloudItemCount == 0 || cloudConfirmed) && run.restorePointProblem == nil }
}

struct ReviewOutcome: Hashable {
    enum Status: Hashable {
        case inTrash
        case deleted
        /// A permanent removal stopped after the move to the Trash: off the map, with Safety's sentence.
        case leftInTrash(String)
        case notMoved(String)
    }

    let name: String
    let path: String
    let bytes: UInt64
    let status: Status
}

extension DiskMapModel {
    func stageSelection() {
        switch selection {
        case .node(let node): stage(node)
        case .smallerItems: stagingMessage = "Open the group in the list and choose the items to remove"
        case nil: break
        }
    }

    func stage(_ node: Int) {
        guard let tree else { return }
        stagingMessage = pile.add(node, in: tree).map(DiskMapText.staging)
    }

    func unstage(_ node: Int) {
        pile.remove(node)
    }

    func beginReview() {
        let items = pile.items
        guard !items.isEmpty else { return }
        let run = RemovalRun(mode: hardcore.mode, urls: items.map(\.url), support: support)
        review = ReviewState(items: items, run: run)
        // Items that still go to the Trash in hardcore mode (D4) free nothing now.
        Task { await measure(items, only: items.map(\.url).filter { run.trashOnly[$0] == nil }) }
    }

    /// "Frees about X now": clone- and hard-link-aware, from the engine (F-0004), never the map's on-disk sum.
    private func measure(_ items: [StagedItem], only urls: [URL]) async {
        let estimate: ReviewState.Estimate
        if let engine = scanEngine, let result = try? await engine.reclaimable(urls) {
            estimate = .measured(result)
        } else {
            estimate = .unavailable
        }
        if review?.items == items { review?.estimate = estimate }
    }

    /// Moves the reviewed items to the Trash, or deletes them in the mode the sheet opened with. Never through the
    /// administrator helper: root-owned items stay "Needs admin" here (DESIGN-debloat D8, r2: sec 3a).
    func confirmReview() async {
        guard let review, review.canConfirm else { return }
        self.review?.phase = .moving
        guard let run = await support.makeRestorePoint(in: self, \.review) else {
            self.review.ifStill(review.id) { $0.phase = .confirm }
            return
        }
        let requests = review.items.map { TrashItem(url: $0.url, expectedIdentity: $0.identity) }
        let (report, freed) = await support.measuring(run.mode, requests.map(\.url)) {
            if let trashService {
                await trashService.remove(requests, mode: run.mode, cloudConfirmed: review.cloudConfirmed, restorePoint: run.restorePoint)
            } else {
                TrashReport(batch: UUID(), outcomes: requests.map { .refused($0.url, .notImplemented) })
            }
        }
        // Applied before `review` is touched: the sheet may be gone by now, and the report must land anyway.
        let outcomes = apply(report, mode: run.mode)
        self.review.ifStill(review.id) {
            $0.run.freed = freed
            $0.phase = .done(outcomes)
        }
    }

    /// "Delete Permanently" after the restore point failed: go on without one.
    func confirmWithoutRestorePoint() async {
        review?.run.restorePointProblem = nil
        review?.run.goesOnWithoutRestorePoint = true
        await confirmReview()
    }

    /// Splices trashed and deleted items out of the tree in memory, without a rescan (F-0052). Each removal
    /// subtracts only the bytes that node was charged, so a hard link counted at 0 B takes 0 B with it (F-0063).
    /// Refused and failed items stay on the map and in the pile, with the reason, unless the failure left the item
    /// in the Trash.
    @discardableResult
    func apply(_ report: TrashReport, mode: DeletionMode = .trash) -> [ReviewOutcome] {
        guard var tree else { return [] }
        var outcomes: [ReviewOutcome] = []
        var removedAny = false
        for outcome in report.outcomes {
            switch outcome {
            case .trashed(let original, let trashedTo):
                guard let item = stagedItem(at: original) else { continue }
                if !tree.flags(of: item.node).contains(.removed), let parent = tree.parent(of: item.node) {
                    tree.removeSubtree(at: item.node)
                    trashed.append(TrashedItem(node: item.node, parent: parent, name: item.name, bytes: item.bytes, trashedTo: trashedTo))
                    removedAny = true
                }
                pile.remove(item.node)
                outcomes.append(ReviewOutcome(name: item.name, path: original.path, bytes: item.bytes, status: .inTrash))
            case .deleted(let original), .failed(let original, _) where outcome.isLeftInTrash:
                // Gone for good, or stopped halfway with the rest in the Trash: off the map like a trashed item, but
                // not "In Trash", whose bytes it would overstate.
                guard let item = stagedItem(at: original) else { continue }
                if !tree.flags(of: item.node).contains(.removed), tree.parent(of: item.node) != nil {
                    tree.removeSubtree(at: item.node)
                    removedAny = true
                }
                pile.remove(item.node)
                let status: ReviewOutcome.Status = outcome.isDeleted ? .deleted : .leftInTrash(outcome.words(in: mode))
                outcomes.append(ReviewOutcome(name: item.name, path: original.path, bytes: item.bytes, status: status))
            case .refused(let url, let reason):
                outcomes.append(notMoved(url, DiskMapText.refusal(reason)))
            case .failed(let url, let message):
                // Permanent failures are Safety's own sentences ("Partly deleted. …"), shown as they are.
                outcomes.append(notMoved(url, mode == .permanent ? outcome.words(in: mode) : "Could not move: \(message)"))
            }
        }
        guard removedAny else { return outcomes }
        self.tree = tree
        treeDidChange()
        leaveRemovedNodes(in: tree)
        return outcomes
    }

    /// Bytes moved to the Trash this session. Not freed until the Trash is emptied (F-0042).
    var inTrashBytes: UInt64 { trashed.reduce(0) { $0 + $1.bytes } }

    func trashed(from parent: Int) -> [TrashedItem] {
        trashed.filter { $0.parent == parent }
    }

    private func notMoved(_ url: URL, _ reason: String) -> ReviewOutcome {
        let item = stagedItem(at: url)
        if let item { pile.setNote(reason, for: item.node) }
        return ReviewOutcome(name: item?.name ?? url.lastPathComponent, path: url.path, bytes: item?.bytes ?? 0, status: .notMoved(reason))
    }

    private func stagedItem(at url: URL) -> StagedItem? {
        let path = url.standardizedFileURL.path
        return pile.items.first { $0.url.standardizedFileURL.path == path }
    }

    /// Focus, history and selection move off anything that was just trashed.
    private func leaveRemovedNodes(in tree: ScanTree) {
        let isGone = tree.isRemoved
        var target = focus
        while isGone(target), let parent = tree.parent(of: target) { target = parent }
        focus = target
        backStack.removeAll(where: isGone)
        forwardStack.removeAll(where: isGone)
        switch selection {
        case .node(let node) where isGone(node): selection = nil
        case .smallerItems: selection = nil
        default: break
        }
    }
}
