import Foundation
import MacontrolCore
import Observation
import Safety

/// Everything macontrol moved to the Trash, with Undo per batch.
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

    /// Bytes still in the Trash from every batch. Trashing frees nothing until the Trash is emptied (F-0042).
    var inTrashBytes: UInt64 {
        entries.filter { !$0.restored }.reduce(0) { $0 + $1.allocated }
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
        func entry(_ batch: UUID, _ minutesAgo: Double, _ path: String, _ gigabytes: Double, restored: Bool = false) -> JournalEntry {
            JournalEntry(
                batch: batch, date: Date(timeIntervalSince1970: 1_790_000_000 - minutesAgo * 60),
                originalPath: path, trashedPath: "/Users/demo/.Trash/\((path as NSString).lastPathComponent)",
                identity: FileIdentity(device: 1, inode: UInt64(gigabytes * 1000)),
                allocated: UInt64(gigabytes * 1_000_000_000), restored: restored
            )
        }
        return HistoryModel(trash: nil, entries: [
            entry(cleaned, 12, "/Users/demo/Library/Caches/com.example.Editor", 1.3),
            entry(cleaned, 12, "/Users/demo/Library/Developer/Xcode/DerivedData/Macontrol-abc", 6.8),
            entry(uninstalled, 60 * 26, "/Applications/Editor.app", 0.62, restored: true),
            entry(uninstalled, 60 * 26, "/Users/demo/Library/Application Support/com.example.Editor", 1.4, restored: true),
        ])
    }
}

/// One Move to Trash action: a clean, an uninstall or a Disk Map delete.
struct HistoryBatch: Identifiable {
    let id: UUID
    let entries: [JournalEntry]

    var date: Date { entries.map(\.date).min() ?? .distantPast }
    var inTrash: [JournalEntry] { entries.filter { !$0.restored } }
    var canUndo: Bool { !inTrash.isEmpty }

    var title: String {
        let names = entries.map { ($0.originalPath as NSString).lastPathComponent }
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
    }

    /// Never "freed": a same-volume trash is a rename and frees 0 bytes until the Trash is emptied (F-0042).
    var status: String {
        if inTrash.isEmpty { return "Put back" }
        let bytes = inTrash.reduce(0) { $0 + $1.allocated }.formattedBytes
        let partly = inTrash.count < entries.count ? "Partly put back. " : ""
        return "\(partly)In Trash, frees \(bytes) when emptied"
    }
}
