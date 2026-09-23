import Darwin

/// One directory entry as `getattrlistbulk` reported it.
struct BulkEntry {
    var nameStart: Int
    var nameLength: Int
    /// Per-entry error (ATTR_CMN_ERROR). When non-zero only the name is valid.
    var error: Int32 = 0
    var device: Int32 = 0
    var type: UInt32 = 0
    var modified: Int = 0
    var fileFlags: UInt32 = 0
    var inode: UInt64 = 0
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 1
    var logical: UInt64 = 0
    var allocated: UInt64 = 0
    /// Only with `BulkReader(extended: true)`; nil when the volume does not report it.
    var privateSize: UInt64?
    var cloneID: UInt64 = 0
    var cloneRefCount: UInt32 = 0
    /// EF_MAY_SHARE_BLOCKS: some of the file's blocks may belong to a clone.
    var mayShareBlocks = false

    var isDirectory: Bool { type == UInt32(VDIR.rawValue) }
    var isSymlink: Bool { type == UInt32(VLNK.rawValue) }
    var isDataless: Bool { fileFlags & UInt32(SF_DATALESS) != 0 }

    /// A folder the walk enters: not a mount point or automount trigger (F-0031), and not an
    /// evicted iCloud folder, whose listing would download it (F-0019).
    var isWalkable: Bool { isDirectory && error == 0 && mountStatus == 0 && !isDataless }
}

/// The entries of one directory. Reused across directories by one worker.
struct Listing {
    var entries: [BulkEntry] = []
    var names: [UInt8] = []

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        names.removeAll(keepingCapacity: true)
    }

    func name(of entry: BulkEntry) -> ArraySlice<UInt8> {
        names[entry.nameStart..<entry.nameStart + entry.nameLength]
    }
}

/// Reads whole directories with `getattrlistbulk` into a heap buffer owned by one worker thread.
///
/// A heap buffer (not a stack one) keeps nesting depth independent of thread stack size (F-0044).
/// Record layout, verified on APFS with FSOPT_PACK_INVAL_ATTRS: length, returned set, ERROR, the
/// common attributes in bit order, then the directory attributes for VDIR or the file attributes for
/// everything else, then the extended attributes for every entry. All fields are 4-byte aligned.
final class BulkReader {
    static let bufferSize = 256 * 1024

    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: BulkReader.bufferSize, alignment: 8)
    private var request = attrlist()
    private let options: UInt64
    private let extended: Bool

    /// `extended` adds PRIVATESIZE, CLONEID, EXT_FLAGS and CLONE_REFCNT, which cost ~65% more kernel CPU
    /// (bench-scan-engines "Baseline"), so only `reclaimable` asks for them.
    init(extended: Bool) {
        self.extended = extended
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        var options = UInt64(FSOPT_NOFOLLOW) | UInt64(FSOPT_PACK_INVAL_ATTRS)
        if extended {
            request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID)
                | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) | attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)
            options |= UInt64(FSOPT_ATTR_CMN_EXTENDED)
        }
        self.options = options
    }

    deinit { buffer.deallocate() }

    /// Appends every entry of the open directory `fd` to `listing`.
    /// Returns 0, or the errno that stopped the listing; entries read before the error are kept.
    func read(_ fd: Int32, into listing: inout Listing) -> Int32 {
        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, options)
            if count == 0 { return 0 }
            if count < 0 {
                if errno == EINTR { continue }
                return errno
            }
            var offset = 0
            for _ in 0..<count {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length > 0, offset + length <= Self.bufferSize else { return EIO }
                parse(UnsafeRawBufferPointer(start: buffer + offset, count: length), into: &listing)
                offset += length
            }
        }
    }

    private func parse(_ record: UnsafeRawBufferPointer, into listing: inout Listing) {
        var cursor = Cursor(record: record, offset: 4)
        let returnedCommon = cursor.take(UInt32.self)
        cursor.offset = 24
        var entry = BulkEntry(nameStart: listing.names.count, nameLength: 0)
        if returnedCommon & attrgroup_t(ATTR_CMN_ERROR) != 0 { entry.error = Int32(bitPattern: cursor.take(UInt32.self)) }

        let nameField = cursor.offset
        let nameOffset = Int(cursor.take(Int32.self))
        let nameLength = Int(cursor.take(UInt32.self)) - 1  // includes the NUL
        let nameStart = nameField + nameOffset
        guard nameLength > 0, nameStart >= 0, nameStart + nameLength <= record.count else { return }
        let name = UnsafeRawBufferPointer(rebasing: record[nameStart..<nameStart + nameLength])
        if name.count <= 2 && name.allSatisfy({ $0 == UInt8(ascii: ".") }) { return }
        listing.names.append(contentsOf: name)
        entry.nameLength = nameLength
        guard entry.error == 0 else {
            listing.entries.append(entry)
            return
        }

        entry.device = cursor.take(Int32.self)
        entry.type = cursor.take(UInt32.self)
        entry.modified = cursor.take(Int.self)
        cursor.offset += 8  // tv_nsec
        entry.fileFlags = cursor.take(UInt32.self)
        entry.inode = cursor.take(UInt64.self)
        if entry.isDirectory {
            entry.mountStatus = cursor.take(UInt32.self)
        } else {
            entry.linkCount = cursor.take(UInt32.self)
            entry.logical = cursor.take(UInt64.self)
            entry.allocated = cursor.take(UInt64.self)
        }
        if extended {
            let returnedExtended = record.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            let privateSize = cursor.take(UInt64.self)
            if returnedExtended & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 { entry.privateSize = privateSize }
            entry.cloneID = cursor.take(UInt64.self)
            entry.mayShareBlocks = cursor.take(UInt64.self) & 0x1 != 0  // EF_MAY_SHARE_BLOCKS, sys/stat.h
            entry.cloneRefCount = cursor.take(UInt32.self)
        }
        guard cursor.offset <= record.count else { return }  // a malformed record never becomes an entry
        listing.entries.append(entry)
    }
}

private struct Cursor {
    let record: UnsafeRawBufferPointer
    var offset: Int

    /// Reads past the end yield 0; the caller rejects the record by checking `offset` afterwards.
    mutating func take<T: FixedWidthInteger>(_: T.Type) -> T {
        defer { offset += MemoryLayout<T>.size }
        guard offset + MemoryLayout<T>.size <= record.count else { return 0 }
        return record.loadUnaligned(fromByteOffset: offset, as: T.self)
    }
}
