import Darwin
import Foundation
import MacontrolCore

/// Sums one item for `ScanEngine.measure` without keeping a tree.
final class MeasureSink: WalkSink {
    static let extras: BulkReader.Extras = .changeTime

    private var allocated: UInt64 = 0
    private var logical: UInt64 = 0
    private var fileCount = 0
    private var newest: Int
    private var incomplete = false
    private var seenHardLinks = Set<FileIdentity>()

    /// `root` is the item's own `lstat`: adding or deleting a direct child changes only the root's times.
    init(root: stat) {
        newest = root.newestChange
    }

    var measurement: ItemMeasurement {
        ItemMeasurement(
            allocated: allocated, logical: logical, fileCount: fileCount,
            newestModification: Date(timeIntervalSince1970: TimeInterval(newest)), isIncomplete: incomplete
        )
    }

    func add(_ listing: Listing, to folder: Int32, walkableNodes: inout [Int32]) {
        for entry in listing.entries {
            guard entry.error == 0 else {
                incomplete = true
                continue
            }
            // Folders too: a rename or delete inside one changes only the folder's own times.
            newest = max(newest, entry.modified, entry.changed)
            if entry.isDirectory {
                if entry.isWalkable { walkableNodes.append(folder) }
                continue
            }
            fileCount += 1
            if entry.linkCount > 1 && !seenHardLinks.insert(FileIdentity(device: entry.device, inode: entry.inode)).inserted { continue }
            if !entry.isDataless { allocated += entry.allocated }
            logical += entry.logical
        }
    }

    func flag(_ folder: Int32, _ flags: NodeFlags) {
        incomplete = true
    }
}

extension stat {
    /// Newer of mtime and ctime. Tools backdate mtime; ctime is the kernel's record of the last change.
    var newestChange: Int { max(st_mtimespec.tv_sec, st_ctimespec.tv_sec) }
}
