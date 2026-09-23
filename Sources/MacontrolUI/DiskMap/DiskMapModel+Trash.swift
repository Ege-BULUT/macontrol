import Foundation
import MacontrolCore
import Safety

/// The review sheet between the Discard Pile and the Trash.
struct ReviewState {
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

    let items: [StagedItem]
    var estimate: Estimate = .measuring
    var phase: Phase = .confirm

    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

struct ReviewOutcome: Hashable {
    enum Status: Hashable {
        case inTrash
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
        review = ReviewState(items: items)
        Task { await measure(items) }
    }

    /// "Frees about X now": clone- and hard-link-aware, from the engine (F-0004), never the map's on-disk sum.
    private func measure(_ items: [StagedItem]) async {
        let estimate: ReviewState.Estimate
        if let engine = scanEngine, let result = try? await engine.reclaimable(items.map(\.url)) {
            estimate = .measured(result)
        } else {
            estimate = .unavailable
        }
        if review?.items == items { review?.estimate = estimate }
    }

    func confirmReview() async {
        guard let items = review?.items, review?.phase == .confirm else { return }
        review?.phase = .moving
        let requests = items.map { TrashItem(url: $0.url, expectedIdentity: $0.identity) }
        let report: TrashReport = if let trashService {
            await trashService.moveToTrash(requests)
        } else {
            TrashReport(batch: UUID(), outcomes: requests.map { .refused($0.url, .notImplemented) })
        }
        review?.phase = .done(apply(report))
    }

    /// Splices trashed items out of the tree in memory, without a rescan (F-0052). Each removal
    /// subtracts only the bytes that node was charged, so a hard link counted at 0 B takes 0 B with it (F-0063).
    /// Refused and failed items stay on the map and in the pile, with the reason.
    @discardableResult
    func apply(_ report: TrashReport) -> [ReviewOutcome] {
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
            case .refused(let url, let reason):
                outcomes.append(notMoved(url, DiskMapText.refusal(reason)))
            case .failed(let url, let message):
                outcomes.append(notMoved(url, "Could not move: \(message)"))
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
        func isGone(_ node: Int) -> Bool {
            tree.path(to: node).contains { tree.flags(of: $0).contains(.removed) }
        }
        while isGone(focus), let parent = tree.parent(of: focus) { focus = parent }
        backStack.removeAll(where: isGone)
        forwardStack.removeAll(where: isGone)
        switch selection {
        case .node(let node) where isGone(node): selection = nil
        case .smallerItems: selection = nil
        default: break
        }
    }
}
