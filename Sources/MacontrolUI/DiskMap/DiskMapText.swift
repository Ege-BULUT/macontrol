import MacontrolCore
import Safety

/// User-facing wording for flags and refusals, so the list, inspector and review sheet say the same thing.
enum DiskMapText {
    struct Note: Hashable {
        let symbol: String
        let text: String
    }

    /// One note per flag that changes what the size means. Order: most important first.
    static func notes(for flags: NodeFlags) -> [Note] {
        var notes: [Note] = []
        if flags.contains(.removed) { notes.append(Note(symbol: "trash", text: "In Trash: space returns when the Trash is emptied")) }
        if flags.contains(.unreadable) { notes.append(Note(symbol: "lock", text: "Not scanned: needs Full Disk Access. The real size is larger")) }
        if flags.contains(.incomplete) { notes.append(Note(symbol: "exclamationmark.triangle", text: "Partly scanned: the listing stopped early. The real size is larger")) }
        if flags.contains(.dataless) { notes.append(Note(symbol: "icloud", text: "In iCloud: not downloaded, uses no space on this Mac")) }
        if flags.contains(.sharedHardLink) {
            notes.append(Note(symbol: "link", text: "Linked elsewhere: another hard link carries its size"))
        } else if flags.contains(.hardLinked) {
            notes.append(Note(symbol: "link", text: "Hard-linked: other links share these bytes"))
        }
        if flags.contains(.mountPoint) { notes.append(Note(symbol: "externaldrive", text: "Other volume: mounted here, not included")) }
        if flags.contains(.systemProtected) { notes.append(Note(symbol: "lock.shield", text: "Protected by macOS: cannot be removed")) }
        if flags.contains(.package) { notes.append(Note(symbol: "shippingbox", text: "Package: counted and shown as one item")) }
        if flags.contains(.symlink) { notes.append(Note(symbol: "arrowshape.turn.up.right", text: "Symbolic link: its target is not counted here")) }
        if flags.contains(.compressed) { notes.append(Note(symbol: "arrow.down.right.and.arrow.up.left", text: "Compressed by macOS")) }
        return notes
    }

    static func refusal(_ reason: RefusalReason) -> String {
        switch reason {
        case .protectedLocation(let path): "Protected location: macontrol never removes \(path)"
        case .systemProtected: "Protected by macOS (System Integrity Protection or a read-only volume)"
        case .locked: "Locked in Finder. Unlock it there first"
        case .identityChanged: "Changed on disk since the scan. Rescan, then try again"
        case .missing: "No longer there"
        case .needsCloudConfirmation: "In iCloud Drive: removing it removes it on every device"
        case .needsAdministrator: "Owned by the system: needs an administrator. Use Reveal in Finder"
        case .notImplemented: "Moving to the Trash is not available in this build yet"
        }
    }

    static func staging(_ staging: StagingRefusal) -> String {
        switch staging {
        case .protected(let reason): refusal(reason)
        case .scanRoot: "This is the scanned folder itself. Scan its parent to remove it"
        case .otherVolume: "Another volume is mounted here. Eject it in Finder instead"
        case .inTrash: "Already in the Trash"
        case .alreadyStaged: "Already in the Discard Pile"
        case .insideStaged(let name): "Already in the Discard Pile as part of “\(name)”"
        case .insidePackage(let name): "Part of “\(name)”, which is removed as one item"
        }
    }

    /// A size that may be larger: "at least 2 GB" when part of it was not scanned.
    static func size(_ bytes: UInt64, isLowerBound: Bool) -> String {
        isLowerBound ? "at least \(bytes.formattedBytes)" : bytes.formattedBytes
    }

    static let notFullyScanned = "Not fully scanned: it may hold more than shown"
    static let inCloud = "In iCloud Drive: moving it to the Trash removes it on every device"

    static func itemCount(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }

    static func smallerItems(_ count: Int) -> String {
        count == 1 ? "1 smaller item" : "\(count.formatted()) smaller items"
    }

    static func percent(_ part: UInt64, of whole: UInt64) -> String {
        guard whole > 0 else { return "0%" }
        return (Double(part) / Double(whole)).formatted(.percent.precision(.fractionLength(0...1)))
    }
}
