import Foundation
import MacontrolCore

/// One thing the user asked to move to the Trash.
public struct TrashItem: Sendable, Hashable {
    public var url: URL
    /// Identity the scan saw. If the path names another object now, the item is refused.
    public var expectedIdentity: FileIdentity?
    /// Descendants the user unchecked. The item is then trashed piece by piece so these stay (F-0026).
    public var keep: [URL]

    public init(url: URL, expectedIdentity: FileIdentity?, keep: [URL] = []) {
        self.url = url
        self.expectedIdentity = expectedIdentity
        self.keep = keep
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
    /// Root-owned. v1 has no privileged helper; the UI offers Reveal in Finder instead.
    case needsAdministrator
    case notImplemented
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

/// One line of the undo journal (JSON Lines, mode 0600).
public struct JournalEntry: Codable, Sendable, Hashable {
    public var batch: UUID
    public var date: Date
    public var originalPath: String
    public var trashedPath: String
    public var identity: FileIdentity
    public var allocated: UInt64
    public var restored: Bool

    public init(batch: UUID, date: Date, originalPath: String, trashedPath: String, identity: FileIdentity, allocated: UInt64, restored: Bool) {
        self.batch = batch
        self.date = date
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.identity = identity
        self.allocated = allocated
        self.restored = restored
    }
}

/// The only code in macontrol that moves or deletes user files (enforced by SafetyTests/SinkAuditTests).
///
/// PLACEHOLDER (scaffold): refuses everything, so UI work can never touch real files.
/// M7 implements docs/ARCHITECTURE.md "Deletion model".
public actor TrashService {
    public let journalURL: URL

    public init(journalURL: URL = TrashService.defaultJournalURL) {
        self.journalURL = journalURL
    }

    public static var defaultJournalURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Macontrol/trash-journal.jsonl")
    }

    public func moveToTrash(_ items: [TrashItem], cloudConfirmed: Bool = false) -> TrashReport {
        TrashReport(batch: UUID(), outcomes: items.map { .refused($0.url, .notImplemented) })
    }

    public func undo(batch: UUID) -> [RestoreOutcome] {
        []
    }

    public func history() -> [JournalEntry] {
        []
    }
}
