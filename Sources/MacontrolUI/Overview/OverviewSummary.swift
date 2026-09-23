import Cleaner
import Foundation
import MacontrolCore
import ScanEngine

/// Everything the Overview shows, derived from the app state so the views only format it.
struct OverviewSummary {
    struct Capacity {
        var used: UInt64
        var available: UInt64
        var total: UInt64
        var purgeable: UInt64
        var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    }

    struct Item: Identifiable {
        var id: Int
        var name: String
        var bytes: UInt64
        var isFolder: Bool
        /// Relative to the largest item, for the row's bar.
        var share: Double
    }

    var capacity: Capacity?
    var largest: [Item]
    var scannedRoot: String?
    /// nil until the cleaner has scanned.
    var safeToClean: (bytes: UInt64, count: Int)?

    init(volume: VolumeSummary?, tree: ScanTree?, scopeTitle: String? = nil, cleanItems: [CleanupItem], limit: Int = 6) {
        capacity = volume.map {
            // APFS: used is capacity minus container-wide free space; purgeable stays out of "available".
            Capacity(used: $0.capacity - min($0.available, $0.capacity), available: $0.available, total: $0.capacity, purgeable: $0.purgeable)
        }
        scannedRoot = tree.map { scopeTitle ?? FileManager.default.displayName(atPath: $0.rootURL.path) }
        largest = tree.map { Self.largest(in: $0, limit: limit) } ?? []
        let safe = cleanItems.filter(\.isPreselected)
        safeToClean = cleanItems.isEmpty ? nil : (safe.reduce(0) { $0 + $1.measurement.allocated }, safe.count)
    }

    private static func largest(in tree: ScanTree, limit: Int) -> [Item] {
        let children = tree.children(of: ScanTree.root)
            .sorted { tree.allocatedSize(of: $0) > tree.allocatedSize(of: $1) }
            .prefix(limit)
        let top = Double(max(children.first.map(tree.allocatedSize(of:)) ?? 1, 1))
        return children.map { index in
            let bytes = tree.allocatedSize(of: index)
            return Item(
                id: index, name: tree.name(of: index), bytes: bytes,
                isFolder: tree.flags(of: index).contains(.directory), share: Double(bytes) / top
            )
        }
    }
}

extension AppModel {
    var overview: OverviewSummary {
        OverviewSummary(volume: volume, tree: diskMap.tree, scopeTitle: scope?.title, cleanItems: clean.items)
    }

    /// Folders open in the map; a file opens the map at the scan root, where it is listed.
    func openInDiskMap(_ item: OverviewSummary.Item) {
        diskMap.focus = item.isFolder ? item.id : ScanTree.root
        selection = .diskMap
    }

    func findJunk() {
        Task { await clean.scan() }
    }
}
