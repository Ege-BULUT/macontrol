import Foundation
import MacontrolCore
@testable import MacontrolUI
import Safety
import Testing
import TestSupport

@Suite struct HistoryModelTests {
    static func entry(
        _ batch: UUID, _ date: Double, _ path: String, _ bytes: UInt64, restored: Bool = false,
        permanent: Bool = false, restorePoint: String? = nil, asAdministrator: Bool = false
    ) -> JournalEntry {
        JournalEntry(
            batch: batch, date: Date(timeIntervalSince1970: date), originalPath: path,
            trashedPath: permanent ? nil : "/tmp/.Trash/x", identity: FileIdentity(device: 1, inode: bytes), allocated: bytes,
            restored: restored, restorePoint: restorePoint, asAdministrator: asAdministrator
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

    // MARK: Hardcore mode (DESIGN-debloat section 1.5, T-0073 criterion 8)

    /// A permanent batch says so, has no Undo, and is not counted as in the Trash.
    @Test func aPermanentBatchHasNoUndoAndIsNotInTheTrash() {
        let batch = UUID()
        let deleted = HistoryBatch(id: batch, entries: [
            Self.entry(batch, 1, "/a/Old Exports", 2_000_000_000, permanent: true),
            Self.entry(batch, 1, "/a/Cache", 500_000_000, permanent: true),
        ])
        #expect(deleted.status == "Deleted permanently · freed \(UInt64(2_500_000_000).formattedBytes) · can't be undone")
        #expect(!deleted.canUndo && deleted.inTrash.isEmpty)
        let model = HistoryModel(trash: nil, entries: deleted.entries + [Self.entry(UUID(), 2, "/a/Logs", 100)])
        #expect(model.inTrashBytes == 100)

        // A permanent batch whose trash-only items went to the Trash (D4): those can be put back.
        let mixed = HistoryBatch(id: batch, entries: [
            Self.entry(batch, 1, "/a/Cache", 500, permanent: true),
            Self.entry(batch, 1, "/a/Library/Safari", 300),
        ])
        #expect(mixed.canUndo)
        #expect(mixed.status == "Deleted permanently · freed \(UInt64(500).formattedBytes) · can't be undone. In Trash, frees \(UInt64(300).formattedBytes) when emptied")
    }

    @Test func theRestorePointLineCarriesTheRollbackClause() {
        let batch = UUID()
        let name = "com.apple.TimeMachine.2026-09-24-101500.local"
        let with = HistoryBatch(id: batch, entries: [Self.entry(batch, 1, "/a/x", 1, permanent: true, restorePoint: name)])
        #expect(with.restorePointNote == "A restore point was made before this: \(name). Rolling back returns every file on this Mac to "
            + "that moment; anything newer is lost. macOS may have removed it since. To roll back: macOS Recovery > Restore from Time Machine.")
        #expect(HistoryBatch(id: batch, entries: [Self.entry(batch, 1, "/a/x", 1, permanent: true)]).restorePointNote == nil)
    }

    /// Items the administrator helper moved to the Trash count as in the Trash, have no Undo, and point to Finder.
    @Test func helperTrashedItemsHaveNoUndoAndPointToFinder() {
        let batch = UUID()
        let system = HistoryBatch(id: batch, entries: [
            Self.entry(batch, 1, "/Applications/GarageBand.app", 1_900, asAdministrator: true),
            Self.entry(batch, 1, "/Library/Application Support/GarageBand", 900, asAdministrator: true),
        ])
        #expect(!system.canUndo && system.inTrash.count == 2)
        #expect(system.ownedBySystemNote == "2 items belong to the system, so History can't put them back. They're in the Trash: drag them "
            + "back in Finder, which may ask for your administrator password.")
        let mixed = HistoryBatch(id: batch, entries: system.entries + [Self.entry(batch, 1, "/Users/a/Library/Containers/x", 200)])
        #expect(mixed.canUndo, "the user's own items in the batch can still be put back")
        #expect(HistoryModel(trash: nil, entries: mixed.entries).inTrashBytes == 3_000)
    }

    /// The batch's Undo puts back the user's item and leaves the helper-trashed one in the Trash. Real renames in a
    /// temporary folder, through the real TrashService.
    @Test func batchUndoSkipsHelperTrashedItems() async throws {
        let temp = try TemporaryDirectory()
        try temp.directory("home")
        let own = try temp.file("Trash/Own.txt", size: 10)
        let system = try temp.file("Trash/System.txt", size: 10)
        let batch = UUID()
        func line(_ trashed: URL, asAdministrator: Bool) throws -> Data {
            let entry = JournalEntry(
                batch: batch, date: Date(), originalPath: temp.url.appendingPathComponent("home/\(trashed.lastPathComponent)").path,
                trashedPath: trashed.path, identity: try #require(FileIdentity(url: trashed)), allocated: 10, restored: false,
                asAdministrator: asAdministrator
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(entry) + Data([0x0A])
        }
        let journal = temp.url.appendingPathComponent("state/journal.jsonl")
        try temp.directory("state")
        try (line(own, asAdministrator: false) + line(system, asAdministrator: true)).write(to: journal)
        let model = HistoryModel(trash: TrashService(journalURL: journal, home: temp.url.appendingPathComponent("home")))
        await model.reload()
        #expect(model.batches.first?.canUndo == true && model.batches.first?.ownedBySystem.count == 1)

        await model.undo(batch)

        #expect(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("home/Own.txt").path), "the user's item was not put back")
        #expect(FileManager.default.fileExists(atPath: system.path), "the helper-trashed item left the Trash")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("home/System.txt").path))
        #expect(model.undoProblems[batch] == nil)
        #expect(model.batches.first?.canUndo == false && model.batches.first?.ownedBySystem.count == 1)
    }

    @Test func demoHasAPermanentAndAHelperTrashedBatch() {
        let batches = HistoryModel.demo().batches
        #expect(batches.contains { !$0.deleted.isEmpty && $0.deleted.count == $0.entries.count && $0.restorePointNote != nil })
        #expect(batches.contains { $0.ownedBySystemNote != nil && $0.canUndo })
    }
}
