import Foundation
import Safety
import ScanEngine

/// The hardcore half of an open confirmation (DESIGN-debloat sections 1.4 and 2.6). `mode` is fixed when the
/// confirmation opens, so turning the toggle afterwards changes nothing already on screen (section 1.1).
struct RemovalRun: Equatable {
    var mode: DeletionMode = .trash
    /// D4 items and why each still goes to the Trash; empty in Trash mode. They are left out of "Frees up to X".
    var trashOnly: [URL: String] = [:]
    /// Free space where the items live, read when the confirmation opened: the restore point box needs 1 GB.
    var availableAtOpen: UInt64?
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
        availableAtOpen = support.available(urls)
    }

    var isPermanent: Bool { mode == .permanent }

    /// What `rows` can free in this run: rows that still go to the Trash free nothing now (D4).
    func bytes(of rows: [TrashSheetRow]) -> UInt64 {
        rows.filter { trashOnly[$0.url] == nil }.reduce(0) { $0 + $1.bytes }
    }

    var canMakeRestorePoint: Bool { (availableAtOpen ?? 0) >= Self.restorePointMinimum }
    var needsRestorePoint: Bool {
        isPermanent && wantsRestorePoint && canMakeRestorePoint && !goesOnWithoutRestorePoint && restorePoint == nil
    }
}

/// An open confirmation that carries a `RemovalRun`: Clean's review, the uninstall sheet, Disk Map's review.
protocol RemovalConfirmation {
    var run: RemovalRun { get set }
}

/// What a confirmation needs besides TrashService in hardcore mode; each part is injected in tests.
struct RemovalSupport {
    var createRestorePoint: () async throws -> String = { try await RestorePoint.create() }
    /// Available bytes summed over the volumes that hold `urls`, nil when unreadable.
    var available: ([URL]) -> UInt64? = { RemovalSupport.availableSpace(holding: $0) }
    /// Why an item goes to the Trash even in permanent mode (D4), or nil.
    var trashOnlyReason: (URL) -> String? = { TrashOnly.reason(for: $0) }

    /// Fixed numbers for demo data: nothing real is read or made.
    static let demo = RemovalSupport(
        createRestorePoint: { "com.apple.TimeMachine.2026-09-24-101500.local" },
        available: { _ in 131_207_000_000 },
        trashOnlyReason: { TrashOnly.reason(for: $0, home: URL(fileURLWithPath: "/Users/demo")) }
    )

    /// `VolumeSummary.available` of each distinct volume the items' folders are on.
    nonisolated static func availableSpace(holding urls: [URL]) -> UInt64? {
        let volumes = Set(urls.compactMap { try? $0.deletingLastPathComponent().resourceValues(forKeys: [.volumeURLKey]).volume })
        let readings = volumes.compactMap { try? VolumeSummary.of($0).available }
        return readings.isEmpty ? nil : readings.reduce(0, +)
    }

    /// Makes the restore point the confirmation at `path` asks for, showing progress there. False when it failed,
    /// or the confirmation closed meanwhile: the reason is then in the run, and nothing may be deleted until the
    /// user answers.
    func makeRestorePoint<Model: AnyObject, Confirmation: RemovalConfirmation>(
        in model: Model, _ path: ReferenceWritableKeyPath<Model, Confirmation?>
    ) async -> Bool {
        guard model[keyPath: path]?.run.needsRestorePoint == true else { return true }
        model[keyPath: path]?.run.isCreatingRestorePoint = true
        defer { model[keyPath: path]?.run.isCreatingRestorePoint = false }
        do {
            let name = try await createRestorePoint()
            model[keyPath: path]?.run.restorePoint = name
            return model[keyPath: path] != nil
        } catch {
            model[keyPath: path]?.run.restorePointProblem = error.localizedDescription
            return false
        }
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
