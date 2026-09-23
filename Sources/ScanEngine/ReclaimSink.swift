import Darwin
import MacontrolCore

/// Answers "what does trashing this selection free right now" for `ScanEngine.reclaimable` (F-0004).
///
/// - A file frees its PRIVATESIZE: bytes not trapped in a clone or snapshot.
/// - A decmpfs-compressed file reports PRIVATESIZE 0 and frees its ALLOCSIZE instead.
/// - A hard-linked inode frees its bytes only if every link is selected; PRIVATESIZE is per inode,
///   so it is charged once.
/// - A full clone group (same CLONEID, CLONE_REFCNT members) frees its shared blocks once if every
///   member is selected.
/// - The rest of the selection's allocated bytes stay on disk: `sharedElsewhere`.
final class ReclaimSink: WalkSink {
    private struct Group {
        var seen: UInt32 = 0
        var members: UInt32
        var allocated: UInt64 = 0
        var privateBytes: UInt64 = 0
    }

    private struct CloneKey: Hashable {
        var device: Int32
        var cloneID: UInt64
    }

    private var freesNow: UInt64 = 0
    private var shared: UInt64 = 0
    private var incomplete = false
    private var hardLinks: [FileIdentity: Group] = [:]
    private var clones: [CloneKey: Group] = [:]

    var estimate: ReclaimEstimate {
        var frees = freesNow
        var elsewhere = shared
        // `>=`, not `==`: seeing more paths than links (a firmlink alias of a root) must not double-charge (F-0058).
        for group in hardLinks.values {
            if group.seen >= group.members { frees += group.privateBytes } else { elsewhere += group.allocated }
        }
        for group in clones.values {
            if group.seen >= group.members {
                // ponytail: a fully selected group is charged one member's allocation even if a partial
                // clone outside the selection still shares some of it; APFS does not expose extents per file.
                frees += group.allocated
            } else {
                frees += group.privateBytes
                elsewhere += UInt64(group.seen) * group.allocated - group.privateBytes
            }
        }
        return ReclaimEstimate(freesNow: frees, sharedElsewhere: elsewhere, isIncomplete: incomplete)
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
            add(entry)
        }
    }

    func flag(_ folder: Int32, _ flags: NodeFlags) {
        incomplete = true
    }

    func add(_ entry: BulkEntry) {
        if entry.isDataless { return }
        let compressed = entry.fileFlags & UInt32(UF_COMPRESSED) != 0
        let privateBytes = compressed ? entry.allocated : min(entry.privateSize ?? entry.allocated, entry.allocated)
        if entry.linkCount > 1 {
            let key = FileIdentity(device: entry.device, inode: entry.inode)
            hardLinks[key, default: Group(members: entry.linkCount, allocated: entry.allocated, privateBytes: privateBytes)].seen += 1
        } else if entry.mayShareBlocks && entry.cloneRefCount > 1 && entry.cloneID != 0 && !compressed {
            let key = CloneKey(device: entry.device, cloneID: entry.cloneID)
            clones[key, default: Group(members: entry.cloneRefCount)].seen += 1
            clones[key]!.allocated = max(clones[key]!.allocated, entry.allocated)
            clones[key]!.privateBytes += privateBytes
        } else {
            freesNow += privateBytes
            shared += entry.allocated - privateBytes
        }
    }
}
