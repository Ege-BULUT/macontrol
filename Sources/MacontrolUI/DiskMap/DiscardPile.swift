import Foundation
import MacontrolCore
import Safety

/// One item waiting in the Discard Pile.
struct StagedItem: Identifiable, Hashable, Sendable {
    let node: Int
    let url: URL
    let identity: FileIdentity
    let name: String
    let bytes: UInt64
    let isFolder: Bool
    /// It, or a folder inside it, could not be fully listed: `bytes` is a lower bound.
    let isIncomplete: Bool
    /// In iCloud Drive or a cloud provider folder: trashing it removes it on every device, so the review asks first.
    let isInCloud: Bool
    /// Why the last Move to Trash left it here, if it did.
    var note: String?

    var id: Int { node }
}

enum StagingRefusal: Hashable, Sendable {
    case protected(RefusalReason)
    case scanRoot
    case otherVolume
    case inTrash
    case alreadyStaged
    case insideStaged(String)
    /// Inside an app or other package, which is removed as one item (F-0028).
    case insidePackage(String)
}

/// Items chosen for the Trash, checked when they are added so a protected item never gets as far
/// as the review sheet. TrashService checks everything again at delete time.
struct DiscardPile: Sendable {
    private(set) var items: [StagedItem] = []
    private let protection: @Sendable (URL) -> RefusalReason?

    /// `protection` is the add-time safety check. The demo and tests, whose trees name files that do
    /// not exist, pass their own.
    init(protection: @escaping @Sendable (URL) -> RefusalReason? = { ProtectedPaths.refusal(for: $0) }) {
        self.protection = protection
    }

    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    /// `totalBytes` is a lower bound: part of an item was not scanned.
    var isIncomplete: Bool { items.contains(where: \.isIncomplete) }

    func contains(_ node: Int) -> Bool {
        items.contains { $0.node == node }
    }

    /// Adds `node`, or says why not. Staged items inside it are dropped, since trashing it takes them along.
    mutating func add(_ node: Int, in tree: ScanTree) -> StagingRefusal? {
        let flags = tree.flags(of: node)
        let url = tree.url(of: node)
        let ancestors = tree.path(to: node).dropLast()
        if node == ScanTree.root { return .scanRoot }
        if tree.isRemoved(node) { return .inTrash }
        if flags.contains(.systemProtected) { return .protected(.systemProtected) }
        if flags.contains(.mountPoint) { return .otherVolume }
        if let package = ancestors.last(where: { tree.flags(of: $0).contains(.package) }) { return .insidePackage(tree.name(of: package)) }
        var isInCloud = false
        switch protection(url) {
        case nil: break
        case .needsCloudConfirmation?: isInCloud = true
        case let reason?: return .protected(reason)
        }
        if contains(node) { return .alreadyStaged }
        if let holder = items.first(where: { ancestors.contains($0.node) }) { return .insideStaged(holder.name) }

        items.removeAll { tree.path(to: $0.node).contains(node) }
        items.append(StagedItem(
            node: node, url: url, identity: tree.identity(of: node), name: tree.name(of: node),
            bytes: tree.allocatedSize(of: node), isFolder: flags.contains(.directory),
            isIncomplete: tree.hasUnscannedContent(node), isInCloud: isInCloud
        ))
        return nil
    }

    mutating func remove(_ node: Int) {
        items.removeAll { $0.node == node }
    }

    mutating func setNote(_ note: String?, for node: Int) {
        guard let index = items.firstIndex(where: { $0.node == node }) else { return }
        items[index].note = note
    }

    mutating func removeAll() {
        items.removeAll()
    }
}
