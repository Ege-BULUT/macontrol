import Foundation
import MacontrolCore
import Observation
import Safety

/// Everything macontrol moved to the Trash or deleted, with Undo per batch for what is in the Trash.
@Observable
public final class HistoryModel {
    public var entries: [JournalEntry]
    public private(set) var undoing: Set<UUID> = []
    /// Items a batch's Undo could not put back, with the reason, until the next Undo of that batch.
    public private(set) var undoProblems: [UUID: [String]] = [:]
    private let trash: TrashService?

    public init(trash: TrashService?, entries: [JournalEntry] = []) {
        self.trash = trash
        self.entries = entries
    }

    /// Newest first.
    var batches: [HistoryBatch] {
        Dictionary(grouping: entries, by: \.batch)
            .map { HistoryBatch(id: $0.key, entries: $0.value) }
            .sorted { $0.date > $1.date }
    }

    /// Bytes still in the Trash from every batch, helper-trashed items included. Trashing frees nothing until the
    /// Trash is emptied (F-0042), and permanent deletions are not in the Trash at all.
    /// A partly deleted line (`leftInTrash != nil`) is permanent and keeps its full size in `allocated`, so it stays out
    /// of this sum; `HistoryBatch.status` says the rest is in the Trash instead.
    var inTrashBytes: UInt64 {
        entries.filter { !$0.restored && !$0.isPermanent }.reduce(0) { $0 + $1.allocated }
    }

    func reload() async {
        guard let trash else { return }
        entries = await trash.history()
    }

    func undo(_ batch: UUID) async {
        guard let trash, !undoing.contains(batch) else { return }
        undoing.insert(batch)
        defer { undoing.remove(batch) }
        let problems = await trash.undo(batch: batch).compactMap { outcome -> String? in
            guard case .failed(let url, let message) = outcome else { return nil }
            return "\(url.lastPathComponent): \(message)"
        }
        undoProblems[batch] = problems.isEmpty ? nil : problems
        await reload()
    }

    static func demo() -> HistoryModel {
        let cleaned = UUID(uuidString: "6B1E0C4A-5A51-4B8C-9C63-3E1B7D0A2F10")!
        let uninstalled = UUID(uuidString: "0D7F4A2E-8C1B-4E55-A0B9-6F3C2D1E9A77")!
        let deleted = UUID(uuidString: "A3C5E7F9-1B2D-4F60-8A9B-C1D2E3F40516")!
        let debloated = UUID(uuidString: "5E4D3C2B-1A09-4F8E-9D7C-6B5A49382716")!
        func entry(
            _ batch: UUID, _ minutesAgo: Double, _ path: String, _ gigabytes: Double, restored: Bool = false,
            permanent: Bool = false, restorePoint: String? = nil, asAdministrator: Bool = false
        ) -> JournalEntry {
            JournalEntry(
                batch: batch, date: Date(timeIntervalSince1970: 1_790_000_000 - minutesAgo * 60),
                originalPath: path, trashedPath: permanent ? nil : "/Users/demo/.Trash/\((path as NSString).lastPathComponent)",
                identity: FileIdentity(device: 1, inode: UInt64(gigabytes * 1000)),
                allocated: UInt64(gigabytes * 1_000_000_000), restored: restored, restorePoint: restorePoint,
                asAdministrator: asAdministrator
            )
        }
        let snapshot = "com.apple.TimeMachine.2026-09-21-093000.local"
        return HistoryModel(trash: nil, entries: [
            entry(cleaned, 12, "/Users/demo/Library/Caches/com.example.Editor", 1.3),
            entry(cleaned, 12, "/Users/demo/Library/Developer/Xcode/DerivedData/Macontrol-abc", 6.8),
            // Hardcore mode, with a restore point.
            entry(deleted, 60 * 3, "/Users/demo/Movies/Old Exports", 12.4, permanent: true, restorePoint: snapshot),
            entry(deleted, 60 * 3, "/Users/demo/Library/Caches/com.example.Renderer", 2.1, permanent: true, restorePoint: snapshot),
            // An uninstall whose root-owned parts the administrator helper moved to the Trash.
            entry(debloated, 60 * 20, "/Applications/GarageBand.app", 1.9, asAdministrator: true),
            entry(debloated, 60 * 20, "/Library/Application Support/GarageBand", 0.9, asAdministrator: true),
            entry(debloated, 60 * 20, "/Users/demo/Library/Containers/com.apple.garageband10", 0.2),
            entry(uninstalled, 60 * 26, "/Applications/Editor.app", 0.62, restored: true),
            entry(uninstalled, 60 * 26, "/Users/demo/Library/Application Support/com.example.Editor", 1.4, restored: true),
        ])
    }
}

/// One user action: a clean, an uninstall or a Disk Map review, in the Trash or deleted permanently.
struct HistoryBatch: Identifiable {
    let id: UUID
    let entries: [JournalEntry]

    var date: Date { entries.map(\.date).min() ?? .distantPast }
    /// Deleted for good: nothing to put back (DESIGN-debloat section 1.5).
    var deleted: [JournalEntry] { entries.filter { $0.isPermanent && $0.leftInTrash == nil } }
    /// Stopped halfway: part deleted for good, the rest in the Trash under `leftInTrash` (DESIGN-debloat section 2.4).
    var partlyDeleted: [JournalEntry] { entries.filter { $0.isPermanent && $0.leftInTrash != nil } }
    /// Still in the Trash, helper-trashed items included.
    var inTrash: [JournalEntry] { entries.filter { !$0.restored && !$0.isPermanent } }
    /// Moved to the Trash by the administrator helper: no Undo, Finder puts them back (D12).
    var ownedBySystem: [JournalEntry] { inTrash.filter(\.asAdministrator) }
    /// What Undo puts back. It skips permanent and helper-trashed items, as `TrashService.undo` does.
    var canUndo: Bool { inTrash.contains { !$0.asAdministrator } }
    /// The snapshot made before the batch, if the user asked for one.
    var restorePoint: String? { entries.lazy.compactMap(\.restorePoint).first }

    var title: String {
        let names = entries.map { ($0.originalPath as NSString).lastPathComponent }
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
    }

    /// Never "freed" for the Trash: a same-volume trash is a rename and frees 0 bytes until the Trash is emptied (F-0042).
    /// Nor for a permanent batch: the journal holds the items' sizes, not what came back. A restore point or another
    /// snapshot keeps their blocks, and a partly deleted folder is journaled at its full size (T-0073 review 1).
    /// A partly deleted line says where the rest waits, per line, instead of "Deleted permanently".
    var status: String {
        var parts: [String] = []
        if !deleted.isEmpty {
            parts.append("Deleted permanently · \(deleted.reduce(0) { $0 + $1.allocated }.formattedBytes) · can't be undone")
        }
        for entry in partlyDeleted {
            parts.append(PermanentText.partlyDeleted(((entry.leftInTrash ?? "") as NSString).lastPathComponent).trimmingCharacters(in: ["."]))
        }
        if !inTrash.isEmpty {
            let bytes = inTrash.reduce(0) { $0 + $1.allocated }.formattedBytes
            let partly = entries.contains(where: \.restored) ? "Partly put back. " : ""
            parts.append("\(partly)In Trash, frees \(bytes) when emptied")
        }
        return parts.isEmpty ? "Put back" : parts.joined(separator: ". ")
    }

    /// "A restore point was made before this: …", with what rolling back costs (DESIGN-debloat section 1.5, r2: ux 6).
    var restorePointNote: String? {
        restorePoint.map {
            "A restore point was made before this: \($0). Rolling back returns every file on this Mac to that moment; "
                + "anything newer is lost. macOS may have removed it since. To roll back: macOS Recovery > Restore from Time Machine."
        }
    }

    /// Helper-trashed items: History can't put them back (DESIGN-debloat section 1.5, r2: sec 2).
    var ownedBySystemNote: String? {
        let count = ownedBySystem.count
        guard count > 0 else { return nil }
        return "\(count == 1 ? "1 item belongs" : "\(count) items belong") to the system, so History can't put \(count == 1 ? "it" : "them") back. "
            + "\(count == 1 ? "It's" : "They're") in the Trash: drag \(count == 1 ? "it" : "them") back in Finder, which may ask for your administrator password."
    }
}
