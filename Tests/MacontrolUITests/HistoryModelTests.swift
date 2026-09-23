import Foundation
import MacontrolCore
@testable import MacontrolUI
import Safety
import Testing
import TestSupport

@Suite struct HistoryModelTests {
    static func entry(_ batch: UUID, _ date: Double, _ path: String, _ bytes: UInt64, restored: Bool = false) -> JournalEntry {
        JournalEntry(
            batch: batch, date: Date(timeIntervalSince1970: date), originalPath: path,
            trashedPath: "/tmp/.Trash/x", identity: FileIdentity(device: 1, inode: bytes), allocated: bytes, restored: restored
        )
    }

    @Test func entriesGroupByBatchNewestFirst() {
        let old = UUID(), new = UUID()
        let model = HistoryModel(trash: nil, entries: [
            Self.entry(old, 100, "/a/One", 1),
            Self.entry(new, 200, "/a/Two", 2),
            Self.entry(old, 100, "/a/Three", 3),
        ])
        #expect(model.batches.map(\.id) == [new, old])
        #expect(model.batches.last?.entries.count == 2)
        #expect(model.batches.last?.title == "One and 1 more")
        #expect(model.batches.first?.title == "Two")
    }

    /// F-0042: trashing frees nothing until the Trash is emptied, so the UI never says "freed".
    @Test func statusSaysInTrashNeverFreed() {
        let batch = UUID()
        let inTrash = HistoryBatch(id: batch, entries: [Self.entry(batch, 1, "/a/Cache", 1_300_000_000)])
        #expect(inTrash.status == "In Trash, frees \(UInt64(1_300_000_000).formattedBytes) when emptied")
        #expect(inTrash.canUndo)

        let partly = HistoryBatch(id: batch, entries: [
            Self.entry(batch, 1, "/a/Cache", 1_000_000_000),
            Self.entry(batch, 1, "/a/Logs", 5, restored: true),
        ])
        #expect(partly.status.hasPrefix("Partly put back. In Trash, frees"))

        let restored = HistoryBatch(id: batch, entries: [Self.entry(batch, 1, "/a/Cache", 1, restored: true)])
        #expect(restored.status == "Put back")
        #expect(!restored.canUndo)

        for status in [inTrash.status, partly.status, restored.status] {
            #expect(!status.localizedCaseInsensitiveContains("freed"))
        }
    }

    @Test func inTrashTotalSkipsRestoredItems() {
        let batch = UUID()
        let model = HistoryModel(trash: nil, entries: [
            Self.entry(batch, 1, "/a/One", 100),
            Self.entry(batch, 1, "/a/Two", 50, restored: true),
        ])
        #expect(model.inTrashBytes == 100)
    }

    @Test func undoGoesThroughTrashServiceAndReloadsTheJournal() async throws {
        let folder = try TemporaryDirectory()
        let trash = TrashService(journalURL: folder.url.appendingPathComponent("journal.jsonl"))
        let batch = UUID()
        let model = HistoryModel(trash: trash, entries: [Self.entry(batch, 1, "/a/One", 100)])

        await model.undo(batch)

        #expect(model.entries == (await trash.history()))
        #expect(model.undoing.isEmpty)
        #expect(model.undoProblems[batch] == nil)
    }
}
