import Foundation
import MacontrolCore

/// Sums one item for `ScanEngine.measure` without keeping a tree.
final class MeasureSink: WalkSink {
    private var allocated: UInt64 = 0
    private var logical: UInt64 = 0
    private var fileCount = 0
    private var newest: Int?
    private var incomplete = false
    private var seenHardLinks = Set<FileIdentity>()

    var measurement: ItemMeasurement {
        ItemMeasurement(
            allocated: allocated, logical: logical, fileCount: fileCount,
            newestModification: newest.map { Date(timeIntervalSince1970: TimeInterval($0)) }, isIncomplete: incomplete
        )
    }

    func add(_ listing: Listing, to folder: Int32, walkableNodes: inout [Int32]) {
        for entry in listing.entries {
            guard entry.error == 0 else {
                incomplete = true
                continue
            }
            if entry.isDirectory {
                if entry.isWalkable { walkableNodes.append(folder) }
                continue
            }
            fileCount += 1
            newest = max(newest ?? entry.modified, entry.modified)
            if entry.linkCount > 1 && !seenHardLinks.insert(FileIdentity(device: entry.device, inode: entry.inode)).inserted { continue }
            if !entry.isDataless { allocated += entry.allocated }
            logical += entry.logical
        }
    }

    func flag(_ folder: Int32, _ flags: NodeFlags) {
        incomplete = true
    }
}
