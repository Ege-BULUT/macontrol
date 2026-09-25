import Foundation
import Safety

extension TrashOutcome {
    var url: URL {
        switch self {
        case .trashed(let original, _): original
        case .deleted(let original): original
        case .refused(let url, _): url
        case .failed(let url, _): url
        }
    }

    var isTrashed: Bool {
        if case .trashed = self { true } else { false }
    }

    var isDeleted: Bool {
        if case .deleted = self { true } else { false }
    }

    /// Gone from where it was: in the Trash or deleted for good.
    var isRemoved: Bool { isTrashed || isDeleted }

    /// Safety removed part of a folder and left the rest in the Trash (DESIGN-debloat section 2.4).
    var isPartlyDeleted: Bool {
        if case .failed(_, let message) = self { message.hasPrefix("Partly deleted") } else { false }
    }

    /// A permanent removal that stopped after the item was moved to the Trash: "Partly deleted. …", "Moved to the
    /// Trash, but not deleted: …" and "Moved to the Trash as "<name>", but nothing in it could be deleted …". The item
    /// is no longer where it was, so lists and the map drop it; the row keeps Safety's sentence (DESIGN-debloat D3).
    /// MERGE NOTE (T-0074/T-0075): these prefixes match Safety's sentences, which this branch's Safety does not have yet.
    /// After the merge, pin them with a test built from Safety's own builders (`@testable import Safety`:
    /// `TrashBatch.partlyDeleted`, `TrashBatch.notDeleted` with and without `asAdministrator`, and the "it changed
    /// there" literal in TrashBatch and PrivilegedExecutor): each must give `isLeftInTrash`, and only `partlyDeleted`
    /// `isPartlyDeleted`. A rewording in Safety would otherwise put an item that left its place back in the lists.
    var isLeftInTrash: Bool { isPartlyDeleted || isWholeInTrash }

    /// Stopped with the whole item in the Trash, nothing deleted: journaled as trashed, so History can put it back and
    /// counts it in the Trash, and so do Clean and Disk Map (T-0073 review 2).
    var isWholeInTrash: Bool {
        if case .failed(_, let message) = self { message.hasPrefix("Moved to the Trash") } else { false }
    }

    /// No longer at its path: in the Trash, deleted, or stopped halfway with the rest in the Trash.
    var leftItsPlace: Bool { isRemoved || isLeftInTrash }

    /// What happened, in words a user can act on. A permanent batch's other failures are Safety's own sentences
    /// ("Moved to the Trash, but not deleted: …"), shown as they are, and so are sentences that already say nothing
    /// moved ("Not removed: the administrator password was not given."), which "Could not move it: " would double.
    func words(in mode: DeletionMode) -> String {
        switch self {
        case .trashed: "Moved to the Trash"
        case .deleted: "Deleted permanently"
        case .refused(_, let reason): reason.words
        case .failed(let url, _) where isPartlyDeleted: PermanentText.partlyDeleted(nameInTrash ?? url.lastPathComponent)
        case .failed(_, let message): mode == .permanent || message.hasPrefix("Not removed") ? message : "Could not move it: \(message)"
        }
    }

    /// The name Safety gives the copy in the Trash: `… the rest is in the Trash as "<name>". Empty the Trash …`. It
    /// runs to that closing phrase, not to the next quote: a name can hold quotes.
    private var nameInTrash: String? {
        guard case .failed(_, let message) = self, let start = message.range(of: "as \"")?.upperBound,
              let end = message.range(of: "\". Empty the Trash", range: start..<message.endIndex)?.lowerBound else { return nil }
        return String(message[start..<end])
    }

    var words: String { words(in: .trash) }
}

extension RefusalReason {
    var words: String {
        switch self {
        case .protectedLocation(let name): "Not moved: macontrol never deletes \(name)"
        case .systemProtected: "Not moved: macOS protects this item"
        case .locked: "Not moved: it is locked (Finder, Get Info)"
        case .holdsLocked(let item): "Not moved: it holds \(item), which is locked (Finder, Get Info)"
        case .identityChanged: "Not moved: it changed since the scan. Scan again."
        case .missing: "Not moved: it is already gone"
        case .needsCloudConfirmation: "Not moved: it is in iCloud, so deleting it would delete it on every device"
        case .needsAdministrator: "Not moved: it needs an administrator. Use Reveal in Finder."
        case .notImplemented: "Not moved: moving to the Trash is not available in this build"
        }
    }
}

extension TrashReport {
    var trashedURLs: Set<URL> { Set(outcomes.filter(\.isTrashed).map(\.url)) }
    /// Whole in the Trash: moved there, or a permanent removal that deleted nothing of it. Their bytes are "In Trash".
    var inTrashURLs: Set<URL> { Set(outcomes.filter { $0.isTrashed || $0.isWholeInTrash }.map(\.url)) }
    var deletedURLs: Set<URL> { Set(outcomes.filter(\.isDeleted).map(\.url)) }
    /// In the Trash, deleted, or stopped halfway with the rest in the Trash: either way the item left its place.
    var removedURLs: Set<URL> { Set(outcomes.filter(\.leftItsPlace).map(\.url)) }

    /// "Moved 2 of 3 items to the Trash"
    func summary(of count: Int) -> String {
        let moved = trashedURLs.count
        if moved == count { return count == 1 ? "Moved to the Trash" : "Moved all \(count) items to the Trash" }
        if moved == 0 { return count == 1 ? "Nothing was moved" : "None of the \(count) items were moved" }
        return "Moved \(moved) of \(count) items to the Trash"
    }
}
