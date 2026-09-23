import Foundation
import MacontrolCore

/// One thing the user asked to move to the Trash.
public struct TrashItem: Sendable, Hashable {
    public var url: URL
    /// Identity the scan saw. If the path names another object now, the item is refused.
    public var expectedIdentity: FileIdentity?
    /// Descendants the user unchecked. The item is then trashed piece by piece so these stay (F-0026).
    public var keep: [URL]
    /// The scan's on-disk size, recorded in the journal for History.
    public var allocated: UInt64

    public init(url: URL, expectedIdentity: FileIdentity?, keep: [URL] = [], allocated: UInt64 = 0) {
        self.url = url
        self.expectedIdentity = expectedIdentity
        self.keep = keep
        self.allocated = allocated
    }
}

public enum RefusalReason: Error, Sendable, Hashable {
    /// A location macontrol never deletes, or never deletes inside; the string names it for the user.
    case protectedLocation(String)
    /// SIP-restricted, sealed or read-only.
    case systemProtected
    /// The user set the Locked flag. It is never cleared for them (F-0024, F-0070).
    case locked
    /// The path now names a different object than the scan saw.
    case identityChanged
    case missing
    /// Inside iCloud Drive or a cloud provider folder: deleting there deletes on every device.
    case needsCloudConfirmation
    /// Not writable by this user (root-owned, as a rule). v1 has no privileged helper; the UI offers Reveal in Finder.
    case needsAdministrator
}

public enum TrashOutcome: Sendable, Hashable {
    case trashed(original: URL, trashedTo: URL)
    case refused(URL, RefusalReason)
    case failed(URL, message: String)
}

public enum RestoreOutcome: Sendable, Hashable {
    case restored(URL)
    case failed(URL, message: String)
}

public struct TrashReport: Sendable {
    public var batch: UUID
    public var outcomes: [TrashOutcome]

    public init(batch: UUID, outcomes: [TrashOutcome]) {
        self.batch = batch
        self.outcomes = outcomes
    }
}

/// Where trashed items go; returns the item's new location.
public struct TrashBackend: Sendable {
    public var moveToTrash: @Sendable (URL) throws -> URL

    public init(moveToTrash: @escaping @Sendable (URL) throws -> URL) {
        self.moveToTrash = moveToTrash
    }

    /// The user's Trash through `FileManager.trashItem`: the item keeps its visible name, Finder gets
    /// its Put Back record, and each volume uses its own Trash (topic-platform-constraints D1-D5;
    /// F-0018, F-0036, F-0053, F-0064). Tests never use this: they pass a folder of their own.
    public static let finder = TrashBackend { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let resulting else { throw CocoaError(.fileWriteUnknown) }
        return resulting as URL
    }
}

/// The only code in macontrol that moves user files (enforced by SafetyTests/SinkAuditTests).
/// Nothing is ever deleted permanently: items go to the Trash, and every move is journaled for Undo.
public actor TrashService {
    public let journalURL: URL
    private let backend: TrashBackend
    private let policy: ProtectionPolicy
    // Trashing blocks on file I/O, so the actor runs on its own queue, not the cooperative pool.
    private let queue = DispatchSerialQueue(label: "macontrol.trash")

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(
        journalURL: URL = TrashService.defaultJournalURL,
        backend: TrashBackend = .finder,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.journalURL = journalURL
        self.backend = backend
        self.policy = ProtectionPolicy(home: home)
    }

    public static var defaultJournalURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Macontrol/trash-journal.jsonl")
    }

    /// Checks and trashes each item on its own, continuing past refusals and failures.
    /// Outcomes follow the order of `items`; an item pieced out by `keep` reports each piece.
    public func moveToTrash(_ items: [TrashItem], cloudConfirmed: Bool = false) -> TrashReport {
        let batch = UUID()
        let journal: FileHandle
        do {
            journal = try TrashJournal(url: journalURL).openForAppending()
        } catch {
            let message = "The undo journal could not be opened: \(error.localizedDescription)"
            return TrashReport(batch: batch, outcomes: items.map { .failed($0.url, message: message) })
        }
        var run = TrashBatch(id: batch, policy: policy, backend: backend, journal: journal, cloudConfirmed: cloudConfirmed)
        return TrashReport(batch: batch, outcomes: run.process(items))
    }

    /// Moves a batch back where it came from, newest first. An item is restored only if it is still
    /// in the Trash as the same object and nothing has taken its original path since.
    public func undo(batch: UUID) -> [RestoreOutcome] {
        let journal = TrashJournal(url: journalURL)
        let pending = journal.entries().filter { $0.batch == batch && !$0.restored }
        guard !pending.isEmpty else { return [] }
        let handle: FileHandle
        do {
            handle = try journal.openForAppending()
        } catch {
            return pending.map { .failed(URL(fileURLWithPath: $0.originalPath), message: "The undo journal could not be opened.") }
        }
        return pending.map { restore($0, recordingTo: handle) }
    }

    /// Every journaled move, newest first.
    public func history() -> [JournalEntry] {
        TrashJournal(url: journalURL).entries()
    }

    private func restore(_ entry: JournalEntry, recordingTo journal: FileHandle) -> RestoreOutcome {
        let original = URL(fileURLWithPath: entry.originalPath)
        guard FileIdentity(url: URL(fileURLWithPath: entry.trashedPath)) == entry.identity else {
            return .failed(original, message: "It is no longer in the Trash.")
        }
        // RENAME_EXCL makes "only if the original path is free" atomic: nothing is ever replaced.
        guard renamex_np(entry.trashedPath, entry.originalPath, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            let message = switch code {
            case EEXIST: "Something else is at its original location now."
            case ENOENT: "The folder it came from no longer exists."
            default: String(cString: strerror(code))
            }
            return .failed(original, message: message)
        }
        var record = entry
        record.date = Date()
        record.restored = true
        // The item is back either way; a lost line only leaves History showing it as trashed.
        try? TrashJournal.append(record, to: journal)
        return .restored(original)
    }
}
