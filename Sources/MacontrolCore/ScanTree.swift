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
/// No node stores its path or a URL: names live in one byte arena and a path is rebuilt from
/// parent links on demand (F-0041 measured 943 B/node for path-per-node trees; this layout is
/// `bytesPerNode` plus the name bytes). Node 0 is the scan root. A child is always added after
/// its parent, so every child index is greater than its parent's.
public struct ScanTree: Sendable {
    public static let root = 0

    /// Fixed storage per node, excluding name bytes and array slack.
    public static let bytesPerNode = 4 + 2 + 4 + 4 + 4 + 8 + 8 + 4 + 2 + 4 + 8

    /// The folder that was scanned, spelled the way the user sees it.
    public let rootURL: URL

    private var nameBytes: [UInt8] = []
    private var nameOffsets: [UInt32] = []
    private var nameLengths: [UInt16] = []
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
        _ = Array(rootURL.lastPathComponent.utf8).withUnsafeBufferPointer { name in
            append(name: name, parent: -1, flags: rootFlags, allocated: 0, logical: 0, identity: rootIdentity)
        }
    }

    public var count: Int { parents.count }

    /// Heap bytes held by the tree's arrays, slack included.
    public var storageBytes: Int {
        nameBytes.capacity + nameOffsets.capacity * 4 + nameLengths.capacity * 2 + parents.capacity * 4
            + firstChildren.capacity * 4 + nextSiblings.capacity * 4 + allocatedSizes.capacity * 8
            + logicalSizes.capacity * 8 + fileCounts.capacity * 4 + nodeFlags.capacity * 2
            + devices.capacity * 4 + inodes.capacity * 8
    }

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
        Array(name.utf8).withUnsafeBufferPointer { bytes in
            addChild(of: parent, nameBytes: bytes, flags: flags, allocated: allocated, logical: logical, identity: identity)
        }
    }

    /// `addChild` with the name as raw file-system bytes, as the scanner reads it.
    @discardableResult
    public mutating func addChild(
        of parent: Int,
        nameBytes name: UnsafeBufferPointer<UInt8>,
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

    /// Charges each hard-linked file to one link, then rolls every node's sizes and file count into
    /// its ancestors. Call once, after the last `addChild`.
    ///
    /// Among links of one `(device, inode)` the one with the byte-wise smallest path keeps the bytes and
    /// the others count 0, so per-folder sizes do not depend on which link a parallel walk met first (F-0054).
    public mutating func finalizeTotals() {
        precondition(!totalsAreFinal, "finalizeTotals called twice")
        chargeHardLinksOnce()
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

    /// Splices a trashed node out and subtracts only the bytes it was charged (F-0063). A removed link
    /// that carried a hard-linked file's bytes hands them to the surviving link with the smallest path,
    /// because the file is still on disk.
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
        rechargeHardLinks(ownedUnder: index)
    }

    public func name(of index: Int) -> String {
        nameBytes.withUnsafeBufferPointer { String(decoding: slice(of: index, in: $0), as: UTF8.self) }
    }

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
            components.append(name(of: current))
            node = parent(of: current)
        }
        return components.reversed().reduce(rootURL) { url, name in
            url.appendingPathComponent(name, isDirectory: false)
        }
    }

    /// The node's path below the root as raw bytes joined by "/"; compares names without Unicode folding.
    public func relativePathBytes(of index: Int) -> [UInt8] {
        var components: [Int] = []
        var node = index
        while node != Self.root {
            components.append(node)
            node = Int(parents[node])
        }
        var path: [UInt8] = []
        nameBytes.withUnsafeBufferPointer { arena in
            for component in components.reversed() {
                if !path.isEmpty { path.append(UInt8(ascii: "/")) }
                path.append(contentsOf: slice(of: component, in: arena))
            }
        }
        return path
    }

    private mutating func chargeHardLinksOnce() {
        var links: [FileIdentity: [Int]] = [:]
        for index in 1..<count where nodeFlags[index].contains(.hardLinked) {
            links[identity(of: index), default: []].append(index)
        }
        for group in links.values where group.count > 1 {
            let paths = group.map { ($0, relativePathBytes(of: $0)) }
            let owner = paths.min { $0.1.lexicographicallyPrecedes($1.1) }!.0
            for link in group where link != owner {
                allocatedSizes[link] = 0
                logicalSizes[link] = 0
                nodeFlags[link].insert(.sharedHardLink)
            }
        }
    }

    private mutating func rechargeHardLinks(ownedUnder removed: Int) {
        var owners: [FileIdentity: Int] = [:]
        var stack = [removed]
        while let node = stack.popLast() {
            if nodeFlags[node].contains(.hardLinked) && !nodeFlags[node].contains(.sharedHardLink) {
                owners[identity(of: node)] = node
            }
            var child = firstChildren[node]
            while child >= 0 {
                stack.append(Int(child))
                child = nextSiblings[Int(child)]
            }
        }
        guard !owners.isEmpty else { return }
        // ponytail: one pass over all nodes per removal that takes an owner link; keep an identity index
        // if trashing many hard-linked files at once gets slow.
        var heirs: [FileIdentity: (node: Int, path: [UInt8])] = [:]
        for node in 1..<count where nodeFlags[node].contains(.sharedHardLink) && owners[identity(of: node)] != nil && isInTree(node) {
            let path = relativePathBytes(of: node)
            if let heir = heirs[identity(of: node)], !path.lexicographicallyPrecedes(heir.path) { continue }
            heirs[identity(of: node)] = (node, path)
        }
        for (identity, heir) in heirs {
            let owner = owners[identity]!
            nodeFlags[heir.node].remove(.sharedHardLink)
            allocatedSizes[heir.node] = allocatedSizes[owner]
            logicalSizes[heir.node] = logicalSizes[owner]
            var ancestor = parent(of: heir.node)
            while let node = ancestor {
                allocatedSizes[node] += allocatedSizes[owner]
                logicalSizes[node] += logicalSizes[owner]
                ancestor = parent(of: node)
            }
        }
    }

    /// False when the node or one of its ancestors was removed.
    private func isInTree(_ index: Int) -> Bool {
        var node = index
        while true {
            if nodeFlags[node].contains(.removed) { return false }
            guard parents[node] >= 0 else { return true }
            node = Int(parents[node])
        }
    }

    private func slice(of index: Int, in arena: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        let start = Int(nameOffsets[index])
        return UnsafeBufferPointer(rebasing: arena[start..<start + Int(nameLengths[index])])
    }

    private mutating func append(
        name: UnsafeBufferPointer<UInt8>,
        parent: Int32,
        flags: NodeFlags,
        allocated: UInt64,
        logical: UInt64,
        identity: FileIdentity
    ) -> Int {
        precondition(nameBytes.count + name.count <= UInt32.max, "name arena full")
        nameOffsets.append(UInt32(nameBytes.count))
        nameLengths.append(UInt16(name.count))
        nameBytes.append(contentsOf: name)
        parents.append(parent)
        firstChildren.append(-1)
        nextSiblings.append(-1)
        allocatedSizes.append(allocated)
        logicalSizes.append(logical)
        fileCounts.append(flags.contains(.directory) ? 0 : 1)
        nodeFlags.append(flags)
        devices.append(identity.device)
        inodes.append(identity.inode)
        return parents.count - 1
    }
}
