import Foundation
import MacontrolCore
@testable import MacontrolUI
import Safety
import Testing

/// The Discard Pile and the review sheet: what is staged, what the sheet asks, and what lands afterwards.
/// Nothing here touches the disk: fixture roots do not exist.
@Suite struct DiskMapReviewTests {
    /// Esc or Cancel while the move runs must not lose the report: `review?.phase = .done(apply(report))`
    /// skipped `apply` once the sheet was gone, so trashed items stayed on the map with no In Trash record.
    @Test func dismissingTheSheetWhileMovingStillAppliesTheReport() async {
        var builder = DiskMapFixtures.Builder()
        let file = builder.file(ScanTree.root, "a.bin", 1_000_000)
        // A journal under a folder that cannot be created: whatever TrashService is linked, nothing moves.
        let journal = URL(fileURLWithPath: "/nonexistent-macontrol-fixture/journal.jsonl")
        let model = DiskMapFixtures.model(builder.finished(), trash: TrashService(journalURL: journal))
        model.stage(file)
        model.beginReview()
        let move = Task { await model.confirmReview() }
        // Sleep, not yield: a yielding loop on the main actor can outrank the move task once another test escalates
        // its priority, and then spins forever. The move may also finish between two looks, so `.done` ends the wait.
        while model.review?.phase == .confirm { try? await Task.sleep(for: .milliseconds(1)) }
        model.review = nil
        await move.value
        #expect(model.pile.items.first?.note != nil, "the report was not applied")
    }

    /// iCloud items can be staged, and the sheet will not move them until the user agrees they go
    /// from every device; only then is `cloudConfirmed` passed on.
    @Test func cloudItemsAreStagedAndNeedConfirmation() async {
        var builder = DiskMapFixtures.Builder()
        let cloud = builder.folder(ScanTree.root, "Mobile Documents")
        let local = builder.file(ScanTree.root, "local.bin", 10)
        let tree = builder.finished()
        let cloudPath = tree.url(of: cloud).path
        let model = DiskMapFixtures.model(tree)
        model.pile = DiscardPile { $0.path.hasPrefix(cloudPath) ? .needsCloudConfirmation : nil }
        model.stage(cloud)
        model.stage(local)
        #expect(model.pile.items.map(\.isInCloud) == [true, false])

        model.beginReview()
        #expect(model.review?.cloudItemCount == 1)
        await model.confirmReview()
        #expect(model.review?.phase == .confirm, "moved without asking")
        model.review?.cloudConfirmed = true
        await model.confirmReview()
        guard case .done(let outcomes) = model.review?.phase else { Issue.record("review did not finish"); return }
        #expect(outcomes.count == 2)
    }

    /// A folder that holds an unreadable folder is staged as a lower bound, and every place says so.
    @Test func unscannedContentIsStagedAsALowerBound() {
        var builder = DiskMapFixtures.Builder()
        let outer = builder.folder(ScanTree.root, "outer")
        builder.folder(outer, "locked", flags: .unreadable)
        builder.file(outer, "seen.bin", 5_000)
        let clean = builder.folder(ScanTree.root, "clean")
        builder.file(clean, "a.bin", 1_000)
        let tree = builder.finished()
        var pile = DiscardPile { _ in nil }
        #expect(pile.add(clean, in: tree) == nil)
        #expect(!pile.isIncomplete)
        #expect(pile.add(outer, in: tree) == nil)
        #expect(pile.items.map(\.isIncomplete) == [false, true])
        #expect(pile.isIncomplete)
        #expect(ReviewState(items: pile.items).isIncomplete)
        #expect(DiskMapText.size(5_000, isLowerBound: true).hasPrefix("at least"))
    }

    /// F-0028: a package is one item. The map does not open it, and nothing inside it can be staged.
    @Test func packagesAreOneItem() {
        var builder = DiskMapFixtures.Builder()
        let app = builder.folder(ScanTree.root, "Tool.app", flags: .package)
        let contents = builder.folder(app, "Contents")
        let binary = builder.file(contents, "Tool", 2_000)
        let model = DiskMapFixtures.model(builder.finished())
        model.drill(into: app)
        #expect(model.focus == ScanTree.root)
        #expect(model.backStack.isEmpty)
        #expect(model.pile.add(binary, in: model.tree!) == .insidePackage("Tool.app"))
        #expect(model.pile.add(app, in: model.tree!) == nil)
    }

    /// F-0063: trashing the hard link that carries the bytes while another link survives must not drop
    /// the totals, because the data stays on disk. The engine's splice re-charges the surviving link.
    @Test func trashingTheCarryingHardLinkKeepsBytesThatStayOnDisk() {
        var builder = DiskMapFixtures.Builder()
        let shared = FileIdentity(device: 1, inode: 999)
        let first = builder.folder(ScanTree.root, "a")
        let second = builder.folder(ScanTree.root, "b")
        let carrier = builder.add(first, "data.bin", bytes: 4 << 20, flags: .hardLinked, identity: shared)
        _ = builder.add(second, "data.bin", bytes: 0, flags: [.hardLinked, .sharedHardLink], identity: shared)
        builder.file(ScanTree.root, "other.bin", 1 << 20)
        let model = DiskMapFixtures.model(builder.finished())
        let before = model.tree!.allocatedSize(of: ScanTree.root)
        model.stage(carrier)
        let url = model.pile.items[0].url
        model.apply(TrashReport(batch: UUID(), outcomes: [.trashed(original: url, trashedTo: URL(fileURLWithPath: "/nonexistent/.Trash/data.bin"))]))
        #expect(model.tree!.allocatedSize(of: ScanTree.root) == before)
    }
}
