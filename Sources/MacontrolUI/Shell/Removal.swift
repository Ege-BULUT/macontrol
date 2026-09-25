import Foundation
import Safety
import ScanEngine

/// The hardcore half of an open confirmation (DESIGN-debloat sections 1.4 and 2.6). `mode` is fixed when the
/// confirmation opens, so turning the toggle afterwards changes nothing already on screen (section 1.1).
struct RemovalRun: Equatable {
    var mode: DeletionMode = .trash
    /// D4 items and why each still goes to the Trash; empty in Trash mode. They are left out of "Frees up to X".
    /// When every item is one, the run opens in Trash mode, since nothing would skip the Trash, and keeps the reasons
    /// for its rows (T-0073 review 2).
    var trashOnly: [URL: String] = [:]
    /// Free space on the startup disk, read when the confirmation opened: the restore point box needs 1 GB there.
    var availableAtOpen: UInt64?
    /// Some item is on another disk. A restore point can't bring it back: `tmutil localsnapshot` snapshots only the
    /// volumes in the Time Machine backup, so the box stays off (T-0073 review 2).
    var isOffStartupDisk = false
    var wantsRestorePoint = false
    var isCreatingRestorePoint = false
    /// Why the restore point could not be made. The sheet then asks before deleting.
    var restorePointProblem: String?
    /// The user chose "Delete Permanently" after the restore point failed.
    var goesOnWithoutRestorePoint = false
    /// The snapshot made before the batch, recorded on its journal lines.
    var restorePoint: String?
    /// The measured change in free space; permanent batches only.
    var freed: UInt64?

    static let restorePointMinimum: UInt64 = 1_000_000_000

    init(mode: DeletionMode = .trash, urls: [URL] = [], support: RemovalSupport? = nil) {
        self.mode = mode
        guard mode == .permanent, let support else { return }
        trashOnly = Dictionary(urls.compactMap { url in support.trashOnlyReason(url).map { (url, $0) } }, uniquingKeysWith: { a, _ in a })
        if !urls.isEmpty && urls.allSatisfy({ trashOnly[$0] != nil }) {
            // A permanent sheet would promise a delete that never happens, then report "Nothing was deleted".
            self.mode = .trash
            return
        }
        isOffStartupDisk = !urls.allSatisfy(support.isOnStartupDisk)
        availableAtOpen = support.startupAvailable()
    }

    var isPermanent: Bool { mode == .permanent }

    /// What `rows` can free in this run: rows that still go to the Trash free nothing now (D4).
    func bytes(of rows: [TrashSheetRow]) -> UInt64 {
        rows.filter { trashOnly[$0.url] == nil }.reduce(0) { $0 + $1.bytes }
    }

    var canMakeRestorePoint: Bool { !isOffStartupDisk && (availableAtOpen ?? 0) >= Self.restorePointMinimum }
    /// Why the box is off, when it is.
    var restorePointUnavailable: String { isOffStartupDisk ? PermanentText.restorePointOtherDisk : PermanentText.restorePointTooFull }
    /// A ticked box still stands for a restore point: none failed, and the user did not go on without one. Only then
    /// may the sheet say "Space comes back when the restore point is removed."
    var promisesRestorePoint: Bool {
        isPermanent && wantsRestorePoint && canMakeRestorePoint && restorePointProblem == nil && !goesOnWithoutRestorePoint
    }
    var needsRestorePoint: Bool {
        isPermanent && wantsRestorePoint && canMakeRestorePoint && !goesOnWithoutRestorePoint && restorePoint == nil
    }
}

/// An open confirmation that carries a `RemovalRun`: Clean's review, the uninstall sheet, Disk Map's review.
protocol RemovalConfirmation {
    /// New for every sheet: a confirm that awaited writes back only to the sheet it started from.
    var id: UUID { get }
    var run: RemovalRun { get set }
}

extension Optional where Wrapped: RemovalConfirmation {
    /// Changes the confirmation only while it is still the one `id` names. While a confirm awaits (the restore point,
    /// the recheck, the batch), its sheet can close and another open, even in the other mode (T-0073 review 1).
    mutating func ifStill(_ id: UUID, _ change: (inout Wrapped) -> Void) {
        guard var confirmation = self, confirmation.id == id else { return }
        change(&confirmation)
        self = confirmation
    }
}

/// What a confirmation needs besides TrashService in hardcore mode; each part is injected in tests.
struct RemovalSupport {
    var createRestorePoint: () async throws -> String = { try await RestorePoint.create() }
    /// Available bytes summed over the volumes that hold `urls`, nil when unreadable: the measured result.
    var available: ([URL]) -> UInt64? = { RemovalSupport.availableSpace(holding: $0) }
    /// Whether a restore point covers the item: it is on the startup disk.
    var isOnStartupDisk: (URL) -> Bool = { RemovalSupport.isOnStartupDisk($0) }
    /// Available bytes on the startup disk, where `tmutil` makes the restore point; nil when unreadable.
    var startupAvailable: () -> UInt64? = { try? VolumeSummary.of(URL(fileURLWithPath: "/System/Volumes/Data")).available }
    /// Why an item goes to the Trash even in permanent mode (D4), or nil.
    var trashOnlyReason: (URL) -> String? = { TrashOnly.reason(for: $0) }

    /// Fixed numbers for demo data: nothing real is read or made.
    static let demo = RemovalSupport(
        createRestorePoint: { "com.apple.TimeMachine.2026-09-24-101500.local" },
        available: { _ in 131_207_000_000 },
        isOnStartupDisk: { _ in true },
        startupAvailable: { 131_207_000_000 },
        trashOnlyReason: { TrashOnly.reason(for: $0, home: URL(fileURLWithPath: "/Users/demo")) }
    )

    /// `VolumeSummary.available` of each distinct volume the items' folders are on.
    nonisolated static func availableSpace(holding urls: [URL]) -> UInt64? {
        let volumes = Set(urls.compactMap { try? $0.deletingLastPathComponent().resourceValues(forKeys: [.volumeURLKey]).volume })
        let readings = volumes.compactMap { try? VolumeSummary.of($0).available }
        return readings.isEmpty ? nil : readings.reduce(0, +)
    }

    /// The item's folder is on the startup disk. Firmlinked paths (/Users, /Applications, /Library) are, and an
    /// external or disk-image volume is not. Unreadable counts as not: the box then stays off.
    nonisolated static func isOnStartupDisk(_ url: URL) -> Bool {
        (try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem == true
    }

    /// Makes the restore point the confirmation at `path` asks for, showing progress there, and returns that
    /// confirmation's run to delete with: its mode, and the restore point's name. Nil when it failed (the reason is then
    /// in the run, and nothing may be deleted until the user answers) or when that confirmation closed meanwhile. Only
    /// that confirmation is written to: another one may be open by the time tmutil returns.
    func makeRestorePoint<Model: AnyObject, Confirmation: RemovalConfirmation>(
        in model: Model, _ path: ReferenceWritableKeyPath<Model, Confirmation?>
    ) async -> RemovalRun? {
        guard let opened = model[keyPath: path] else { return nil }
        guard opened.run.needsRestorePoint else { return opened.run }
        model[keyPath: path]?.run.isCreatingRestorePoint = true
        var name: String?, problem: String?
        do { name = try await createRestorePoint() } catch { problem = error.localizedDescription }
        model[keyPath: path].ifStill(opened.id) {
            $0.run.isCreatingRestorePoint = false
            $0.run.restorePoint = name
            $0.run.restorePointProblem = problem
        }
        guard name != nil, let now = model[keyPath: path], now.id == opened.id else { return nil }
        return now.run
    }

    /// Runs `remove`; for a permanent batch, reads free space right before and after it and returns the change.
    func measuring(
        _ mode: DeletionMode, _ urls: [URL], _ remove: () async throws -> TrashReport
    ) async rethrows -> (TrashReport, freed: UInt64?) {
        guard mode == .permanent else { return (try await remove(), nil) }
        let before = available(urls)
        let report = try await remove()
        guard let before, let after = available(urls) else { return (report, nil) }
        return (report, after > before ? after - before : 0)
    }
}

/// D4: items that go to the Trash even in hardcore mode, with the reason the sheet shows (DESIGN-debloat section 2.2).
/// ponytail: mirrors Safety's trash-only rule by path, for the sheet only; Safety decides what happens and the result
/// rows report it. Swap for `ProtectedPaths.trashOnlyReason(for:)` once permanent-engine merges it (comment on T-0074).
nonisolated enum TrashOnly {
    static let places: [(path: String, reason: String)] = [
        ("Library/Group Containers/group.com.apple.notes", "holds your notes"),
        ("Library/Containers/com.apple.Notes", "holds your notes"),
        ("Library/Application Support/AddressBook", "holds your contacts"),
        ("Library/Calendars", "holds your calendars"),
        ("Library/Safari", "holds your Safari data"),
        ("Library/Application Support/MobileSync/Backup", "holds iPhone and iPad backups"),
    ]

    static func reason(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = url.standardizedFileURL.path.lowercased()
        let base = home.standardizedFileURL.path.lowercased()
        func inside(_ relative: String) -> Bool {
            let place = base + "/" + relative.lowercased()
            return path == place || path.hasPrefix(place + "/")
        }
        if path.contains("com~apple~") || inside("Library/Mobile Documents") { return "stored in iCloud" }
        if inside("Library/CloudStorage") { return "stored in a cloud folder" }
        // Equal, inside it, or holding it.
        return places.first { place in
            let full = base + "/" + place.path.lowercased()
            return inside(place.path) || full.hasPrefix(path + "/")
        }?.reason
    }
}

/// The "Also happens" notes for items the administrator helper removes (DESIGN-debloat section 1.4). The prompt note
/// never says "once": whether macOS asks again within five minutes is not verified (T-0078).
enum AdminText {
    static let badge = "Admin"
    static let badgeHelp = "Owned by the system. macOS asks for your administrator password to remove it."

    static func notes(count: Int, mode: DeletionMode) -> [String] {
        guard count > 0 else { return [] }
        var notes = ["macOS asks for your administrator password for \(count == 1 ? "1 item" : "\(count) items") owned by the system."]
        if mode == .trash {
            notes.append("Finder may ask for your administrator password when you empty the Trash, because these belong to the system.")
        }
        return notes
    }
}
