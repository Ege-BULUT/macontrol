import Foundation
import Safety

extension TrashOutcome {
    var url: URL {
        switch self {
        case .trashed(let original, _): original
        case .refused(let url, _): url
        case .failed(let url, _): url
        }
    }

    var isTrashed: Bool {
        if case .trashed = self { true } else { false }
    }

    /// What happened, in words a user can act on.
    var words: String {
        switch self {
        case .trashed: "Moved to the Trash"
        case .refused(_, let reason): reason.words
        case .failed(_, let message): "Could not move it: \(message)"
        }
    }
}

extension RefusalReason {
    var words: String {
        switch self {
        case .protectedLocation(let name): "Not moved: macontrol never deletes \(name)"
        case .systemProtected: "Not moved: macOS protects this item"
        case .locked: "Not moved: it is locked (Finder, Get Info)"
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

    /// "Moved 2 of 3 items to the Trash"
    func summary(of count: Int) -> String {
        let moved = trashedURLs.count
        if moved == count { return count == 1 ? "Moved to the Trash" : "Moved all \(count) items to the Trash" }
        if moved == 0 { return count == 1 ? "Nothing was moved" : "None of the \(count) items were moved" }
        return "Moved \(moved) of \(count) items to the Trash"
    }
}
