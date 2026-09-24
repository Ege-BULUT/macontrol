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
    /// Remove this item only if nothing exists at this path when its turn comes. An app's leftovers name the
    /// app's bundle here, so no leftover is touched while the app is installed (DESIGN-debloat section 2.1).
    public var requiresGone: URL?

    public init(url: URL, expectedIdentity: FileIdentity?, keep: [URL] = [], allocated: UInt64 = 0, requiresGone: URL? = nil) {
        self.url = url
        self.expectedIdentity = expectedIdentity
        self.keep = keep
        self.allocated = allocated
        self.requiresGone = requiresGone
    }
}

/// Where a batch's items end up: the Trash (v1, the default), or gone for good (hardcore mode).
public enum DeletionMode: String, Sendable, Hashable, Codable {
    case trash, permanent
}

public enum RefusalReason: Error, Sendable, Hashable {
    /// A location macontrol never deletes, or never deletes inside; the string names it for the user.
    case protectedLocation(String)
    /// SIP-restricted, sealed or read-only.
    case systemProtected
    /// The user set the Locked flag. It is never cleared for them (F-0024, F-0070).
    case locked
    /// A folder holding an item the user locked; the string is that item's path inside the folder. Moving the
    /// folder would carry the locked item into the Trash, one Empty Trash away from deletion.
    case holdsLocked(String)
    /// The path now names a different object than the scan saw.
    case identityChanged
    case missing
    /// Inside iCloud Drive or a cloud provider folder: deleting there deletes on every device.
    case needsCloudConfirmation
    /// Not writable by this user (root-owned, as a rule), or nested past PATH_MAX. v1 has no privileged
    /// helper; the UI offers Reveal in Finder.
    case needsAdministrator
    /// Used by callers that have no TrashService (previews, demo mode). TrashService never returns it.
    case notImplemented
}

public enum TrashOutcome: Sendable, Hashable {
    case trashed(original: URL, trashedTo: URL)
    /// Gone for good (permanent mode).
    case deleted(original: URL)
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

/// The only code in macontrol that moves or deletes user files (enforced by SafetyTests/SinkAuditTests).
/// Items go to the Trash, where every move is journaled for Undo, or, in hardcore mode, are deleted for good
/// (DESIGN-debloat section 2), journaled for History with no Undo.
public actor TrashService {
    public let journalURL: URL
    let backend: TrashBackend
    let home: URL
    let engine: RemovalEngine
    let route: Route
    // Removing blocks on file I/O, so the actor runs on its own queue, not the cooperative pool.
    private let queue = DispatchSerialQueue(label: "macontrol.trash")

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Pass 2 of `remove`: `PrivilegedRouting.run`, or a test's stand-in.
    typealias Route = @Sendable (
        _ items: [TrashItem], _ mode: DeletionMode, _ launcher: PrivilegedLauncher, _ batch: UUID, _ journalURL: URL,
        _ home: URL, _ restorePoint: String?
    ) async -> [TrashOutcome]

    public init(
        journalURL: URL = TrashService.defaultJournalURL,
        backend: TrashBackend = .finder,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.init(journalURL: journalURL, backend: backend, home: home, engine: RemovalEngine()) {
            await PrivilegedRouting.run($0, mode: $1, launcher: $2, batch: $3, journalURL: $4, home: $5, restorePoint: $6)
        }
    }

    /// Tests: a remover with hooks, and a stand-in for the administrator helper.
    init(journalURL: URL, backend: TrashBackend, home: URL, engine: RemovalEngine, route: @escaping Route) {
        self.journalURL = journalURL
        self.backend = backend
        self.home = home
        self.engine = engine
        self.route = route
    }

    public static var defaultJournalURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Macontrol/trash-journal.jsonl")
    }

    /// Checks and trashes each item on its own, continuing past refusals and failures: `remove(items, mode: .trash)`
    /// with no administrator. Outcomes follow the order of `items`; an item pieced out by `keep` reports each piece.
    public func moveToTrash(_ items: [TrashItem], cloudConfirmed: Bool = false) -> TrashReport {
        var run: TrashBatch
        do {
            run = try start(.trash, cloudConfirmed: cloudConfirmed, restorePoint: nil)
        } catch {
            return Self.unjournaled(items, error)
        }
        var passes = run.firstPass(items)
        run.lastPass(items, &passes)
        return TrashReport(batch: run.id, outcomes: passes.outcomes.flatMap { $0 })
    }

    /// One batch in either mode, outcomes in the order of `items` (DESIGN-debloat sections 2.1 and 3.6), in three
    /// passes: every item in-process, setting aside those refused with `.needsAdministrator` and deferring those whose
    /// `requiresGone` names a set-aside one; then one helper request for the set-aside items when `administrator` is
    /// given (without it they stay refused, as in v1); then the deferred items. So one call shows at most one dialog.
    /// `restorePoint` is recorded on every journal line.
    public func remove(
        _ items: [TrashItem], mode: DeletionMode, cloudConfirmed: Bool = false,
        administrator: PrivilegedLauncher? = nil, restorePoint: String? = nil
    ) async -> TrashReport {
        var run: TrashBatch
        do {
            run = try start(mode, cloudConfirmed: cloudConfirmed, restorePoint: restorePoint)
        } catch {
            return Self.unjournaled(items, error)
        }
        var passes = run.firstPass(items)
        if let administrator, !passes.setAside.isEmpty {
            let routed = await route(passes.setAside.map { items[$0] }, mode, administrator, run.id, journalURL, home, restorePoint)
            // An item the route did not answer keeps its refusal.
            for (index, outcome) in zip(passes.setAside, routed) { passes.outcomes[index] = [outcome] }
        }
        run.lastPass(items, &passes)
        return TrashReport(batch: run.id, outcomes: passes.outcomes.flatMap { $0 })
    }

    private func start(_ mode: DeletionMode, cloudConfirmed: Bool, restorePoint: String?) throws -> TrashBatch {
        let journal = try TrashJournal(url: journalURL).openForAppending()
        // Built after the journal's folder exists, so the policy protects it under its real path.
        let policy = ProtectionPolicy(home: home, journal: journalURL)
        return TrashBatch(
            id: UUID(), policy: policy, backend: backend, journal: journal, cloudConfirmed: cloudConfirmed,
            mode: mode, restorePoint: restorePoint, engine: engine
        )
    }

    private static func unjournaled(_ items: [TrashItem], _ error: any Error) -> TrashReport {
        let message = "The undo journal could not be opened: \(error.localizedDescription)"
        return TrashReport(batch: UUID(), outcomes: items.map { .failed($0.url, message: message) })
    }

    /// Journals what an administrator helper finished while the app was gone, once, at launch (section 3.8).
    /// Stub (T-0072): does nothing. privileged-helper builds it.
    public func recoverPrivilegedResults() {}

    /// Moves a batch back where it came from, newest first. An item is restored only if it is still
    /// in the Trash as the same object and nothing has taken its original path since. Permanent deletions and
    /// items the administrator helper moved have no Undo (DESIGN-debloat D12).
    public func undo(batch: UUID) -> [RestoreOutcome] {
        let journal = TrashJournal(url: journalURL)
        let pending = journal.entries().filter { $0.batch == batch && !$0.restored && !$0.isPermanent && !$0.asAdministrator }
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
        guard let trashedPath = entry.trashedPath, FileIdentity(url: URL(fileURLWithPath: trashedPath)) == entry.identity else {
            return .failed(original, message: "It is no longer in the Trash.")
        }
        // RENAME_EXCL makes "only if the original path is free" atomic: nothing is ever replaced.
        // RENAME_NOFOLLOW_ANY: a link put in place of a folder on the way cannot send it elsewhere.
        guard renamex_np(trashedPath, entry.originalPath, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else {
            let code = errno
            let message = switch code {
            case EEXIST: "Something else is at its original location now."
            case ENOENT: "The folder it came from no longer exists."
            case ELOOP: "A folder it came from was replaced by a link."
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
