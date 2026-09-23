import Foundation

/// What a node is, and why its size may need explaining.
public struct NodeFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    public static let symlink = NodeFlags(rawValue: 1 << 1)
    /// A bundle folder (.app, .photoslibrary, ...). Sized in full, shown as one item (F-0028).
    public static let package = NodeFlags(rawValue: 1 << 2)
    /// Evicted iCloud / File Provider file: 0 bytes on this Mac, never materialized by a scan.
    public static let dataless = NodeFlags(rawValue: 1 << 3)
    /// Contents could not be listed (EACCES/EPERM, usually missing Full Disk Access). Size is a lower bound (F-0057).
    public static let unreadable = NodeFlags(rawValue: 1 << 4)
    /// Listing stopped part-way for another reason. Size is a lower bound (F-0060).
    public static let incomplete = NodeFlags(rawValue: 1 << 5)
    /// Another volume is mounted here. Not entered, not counted.
    public static let mountPoint = NodeFlags(rawValue: 1 << 6)
    /// The file has more than one hard link.
    public static let hardLinked = NodeFlags(rawValue: 1 << 7)
    /// Another link of the same inode carries the bytes; this node counts 0 (F-0054).
    public static let sharedHardLink = NodeFlags(rawValue: 1 << 8)
    /// decmpfs-compressed (UF_COMPRESSED).
    public static let compressed = NodeFlags(rawValue: 1 << 9)
    /// SIP-restricted or on a read-only volume. Never offered for deletion.
    public static let systemProtected = NodeFlags(rawValue: 1 << 10)
    /// Moved to the Trash from inside the app. Kept only until the next scan.
    public static let removed = NodeFlags(rawValue: 1 << 11)
}

/// A scanned file tree stored as parallel arrays indexed by node number.
///
/// No node stores its path or a URL: a path is rebuilt from parent links on demand
/// (F-0041 measured 943 B/node for path-per-node trees). Node 0 is the scan root.
/// A child is always added after its parent, so every child index is greater than its parent's.
public struct ScanTree: Sendable {
    public static let root = 0

    /// The folder that was scanned, spelled the way the user sees it.
    public let rootURL: URL

    private var names: [String] = []
    private var parents: [Int32] = []
    private var firstChildren: [Int32] = []
    private var nextSiblings: [Int32] = []
    private var allocatedSizes: [UInt64] = []
    private var logicalSizes: [UInt64] = []
    private var fileCounts: [UInt32] = []
    private var nodeFlags: [NodeFlags] = []
    private var devices: [Int32] = []
    private var inodes: [UInt64] = []
    private var totalsAreFinal = false

    public init(rootURL: URL, rootIdentity: FileIdentity, rootFlags: NodeFlags = .directory) {
        self.rootURL = rootURL
        append(name: rootURL.lastPathComponent, parent: -1, flags: rootFlags, allocated: 0, logical: 0, identity: rootIdentity)
    }

    public var count: Int { names.count }

    /// Adds one entry. Files carry their own sizes; folders start with their own entry size
    /// and receive their children's sizes in `finalizeTotals()`.
    @discardableResult
    public mutating func addChild(
        of parent: Int,
        name: String,
        flags: NodeFlags,
        allocated: UInt64,
        logical: UInt64,
        identity: FileIdentity
    ) -> Int {
        precondition(!totalsAreFinal, "addChild after finalizeTotals")
        let index = append(name: name, parent: Int32(parent), flags: flags, allocated: allocated, logical: logical, identity: identity)
        nextSiblings[index] = firstChildren[parent]
        firstChildren[parent] = Int32(index)
        return index
    }

    /// Rolls every node's sizes and file count into its ancestors. Call once, after the last `addChild`.
    public mutating func finalizeTotals() {
        precondition(!totalsAreFinal, "finalizeTotals called twice")
        for index in stride(from: count - 1, to: 0, by: -1) {
            let parent = Int(parents[index])
            allocatedSizes[parent] += allocatedSizes[index]
            logicalSizes[parent] += logicalSizes[index]
            fileCounts[parent] += fileCounts[index]
        }
        totalsAreFinal = true
    }

    /// Adds flags learned after the node was created, such as `.unreadable` when its listing fails.
    public mutating func insertFlags(_ flags: NodeFlags, at index: Int) {
        nodeFlags[index].formUnion(flags)
    }

    /// Splices a trashed node out and subtracts only the bytes it was charged (F-0063).
    public mutating func removeSubtree(at index: Int) {
        precondition(index != Self.root, "cannot remove the scan root")
        guard !nodeFlags[index].contains(.removed), let parent = parent(of: index) else { return }
        nodeFlags[index].insert(.removed)
        if firstChildren[parent] == Int32(index) {
            firstChildren[parent] = nextSiblings[index]
        } else {
            var sibling = Int(firstChildren[parent])
            while nextSiblings[sibling] != Int32(index) { sibling = Int(nextSiblings[sibling]) }
            nextSiblings[sibling] = nextSiblings[index]
        }
        var ancestor: Int? = parent
        while let node = ancestor {
            allocatedSizes[node] -= allocatedSizes[index]
            logicalSizes[node] -= logicalSizes[index]
            fileCounts[node] -= fileCounts[index]
            ancestor = self.parent(of: node)
        }
    }

    public func name(of index: Int) -> String { names[index] }
    public func parent(of index: Int) -> Int? { parents[index] < 0 ? nil : Int(parents[index]) }
    public func allocatedSize(of index: Int) -> UInt64 { allocatedSizes[index] }
    public func logicalSize(of index: Int) -> UInt64 { logicalSizes[index] }
    public func fileCount(of index: Int) -> Int { Int(fileCounts[index]) }
    public func flags(of index: Int) -> NodeFlags { nodeFlags[index] }
    public func identity(of index: Int) -> FileIdentity { FileIdentity(device: devices[index], inode: inodes[index]) }

    /// Children in no particular order; sort for display.
    public func children(of index: Int) -> [Int] {
        var result: [Int] = []
        var child = firstChildren[index]
        while child >= 0 {
            result.append(Int(child))
            child = nextSiblings[Int(child)]
        }
        return result
    }

    public func url(of index: Int) -> URL {
        var components: [String] = []
        var node: Int? = index
        while let current = node, current != Self.root {
            components.append(names[current])
            node = parent(of: current)
        }
        return components.reversed().reduce(rootURL) { url, name in
            url.appendingPathComponent(name, isDirectory: false)
        }
    }

    @discardableResult
    private mutating func append(
        name: String,
        parent: Int32,
        flags: NodeFlags,
        allocated: UInt64,
        logical: UInt64,
        identity: FileIdentity
    ) -> Int {
        names.append(name)
        parents.append(parent)
        firstChildren.append(-1)
        nextSiblings.append(-1)
        allocatedSizes.append(allocated)
        logicalSizes.append(logical)
        fileCounts.append(flags.contains(.directory) ? 0 : 1)
        nodeFlags.append(flags)
        devices.append(identity.device)
        inodes.append(identity.inode)
        return names.count - 1
    }
}
