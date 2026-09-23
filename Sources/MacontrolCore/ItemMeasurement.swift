import Foundation

/// Sizes of one file or folder, measured without keeping a tree.
///
/// `allocated` is bytes on disk with hard links counted once (the disk map number).
/// It is not what deleting the item frees; that is `ReclaimEstimate` (docs/ARCHITECTURE.md, "Size model").
public struct ItemMeasurement: Hashable, Sendable {
    public var allocated: UInt64
    public var logical: UInt64
    public var fileCount: Int
    /// Newest content modification inside the item. Cleanup uses it to skip caches still being written (F-0015).
    public var newestModification: Date?
    /// True when some folder inside could not be read, so the sizes are a lower bound (F-0057).
    public var isIncomplete: Bool

    public init(allocated: UInt64, logical: UInt64, fileCount: Int, newestModification: Date?, isIncomplete: Bool) {
        self.allocated = allocated
        self.logical = logical
        self.fileCount = fileCount
        self.newestModification = newestModification
        self.isIncomplete = isIncomplete
    }

    public static let zero = ItemMeasurement(allocated: 0, logical: 0, fileCount: 0, newestModification: nil, isIncomplete: false)
}

/// What deleting a selection frees right now, and what stays shared with clones, snapshots or other hard links (F-0004).
public struct ReclaimEstimate: Hashable, Sendable {
    public var freesNow: UInt64
    public var sharedElsewhere: UInt64
    /// True when some folder in the selection could not be read, so both numbers are lower bounds (F-0057).
    public var isIncomplete: Bool

    public init(freesNow: UInt64, sharedElsewhere: UInt64, isIncomplete: Bool = false) {
        self.freesNow = freesNow
        self.sharedElsewhere = sharedElsewhere
        self.isIncomplete = isIncomplete
    }
}
