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
}

/// Items chosen for the Trash, checked when they are added so a protected item never gets as far
/// as the review sheet. TrashService checks everything again at delete time.
struct DiscardPile: Sendable {
    private(set) var items: [StagedItem] = []

    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    func contains(_ node: Int) -> Bool {
        items.contains { $0.node == node }
    }

    /// Adds `node`, or says why not. Staged items inside it are dropped, since trashing it takes them along.
    mutating func add(_ node: Int, in tree: ScanTree, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> StagingRefusal? {
        let flags = tree.flags(of: node)
        let url = tree.url(of: node)
        if node == ScanTree.root { return .scanRoot }
        if flags.contains(.removed) { return .inTrash }
        if flags.contains(.systemProtected) { return .protected(.systemProtected) }
        if flags.contains(.mountPoint) { return .otherVolume }
        if let reason = ProtectedPaths.refusal(for: url, home: home) { return .protected(reason) }
        if contains(node) { return .alreadyStaged }
        let ancestors = tree.path(to: node).dropLast()
        if let holder = items.first(where: { ancestors.contains($0.node) }) { return .insideStaged(holder.name) }

        items.removeAll { tree.path(to: $0.node).contains(node) }
        items.append(StagedItem(
            node: node, url: url, identity: tree.identity(of: node), name: tree.name(of: node),
            bytes: tree.allocatedSize(of: node), isFolder: flags.contains(.directory)
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
