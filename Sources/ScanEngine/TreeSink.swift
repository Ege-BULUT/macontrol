import Darwin
import Foundation
import MacontrolCore
import UniformTypeIdentifiers

/// Builds the `ScanTree` for `ScanEngine.scan`.
final class TreeSink: WalkSink {
    static let extras: BulkReader.Extras = []

    var tree: ScanTree
    private(set) var filesVisited = 0
    private(set) var bytesVisited: UInt64 = 0
    private(set) var lastFolder = Int32(ScanTree.root)
    private let dataVolume: DataVolumeLayout?
    private var packageExtensions: [String: Bool] = [:]
    /// Bytes found so far inside each folder at the top of the tree, for `preview()`.
    private var bytesUnderTopLevel: [Int: UInt64] = [:]

    /// `dataVolume` is set when "/" is scanned: the walk lists the Data volume, and its root entries
    /// are placed where the user sees them.
    init(tree: ScanTree, dataVolume: DataVolumeLayout?) {
        self.tree = tree
        self.dataVolume = dataVolume
    }

    var progress: ScanProgress {
        ScanProgress(filesVisited: filesVisited, bytesVisited: bytesVisited, currentPath: tree.url(of: Int(lastFolder)).path)
    }

    func add(_ listing: Listing, to folder: Int32, walkableNodes: inout [Int32]) {
        lastFolder = folder
        filesVisited += listing.entries.count
        if folder == ScanTree.root, let dataVolume {
            addDataVolumeRoot(listing, layout: dataVolume, walkableNodes: &walkableNodes)
            return
        }
        let before = bytesVisited
        for entry in listing.entries {
            let node = add(entry, of: listing, under: Int(folder))
            if entry.isWalkable { walkableNodes.append(Int32(node)) }
        }
        if folder != ScanTree.root { bytesUnderTopLevel[topLevel(of: Int(folder)), default: 0] += bytesVisited - before }
    }

    /// The scan so far, one level deep: the root's largest children with the bytes found inside each
    /// yet, a few times a second while the walk runs (T-0063). Sizes only grow from one call to the next.
    /// Hard links are charged once only in the finished tree, so a preview can run ahead of it by the
    /// size of their extra links.
    func preview(limit: Int = 256) -> ScanTree {
        // One read of the stored tree, not one per child: 3 ms instead of 300 ms for 200k entries at the top.
        let tree = tree
        let children = tree.children(of: ScanTree.root).map { node in
            (node, tree.flags(of: node).contains(.directory) ? bytesUnderTopLevel[node, default: 0] : tree.allocatedSize(of: node))
        }
        var preview = ScanTree(rootURL: tree.rootURL, rootIdentity: tree.identity(of: ScanTree.root))
        // ponytail: past `limit` entries at the top, the smallest are left out, so the preview's total
        // reads low for a folder with thousands of entries at its top; the finished map has them all.
        for (node, bytes) in children.sorted(by: { $0.1 > $1.1 }).prefix(limit) {
            preview.addChild(
                of: ScanTree.root, name: tree.name(of: node), flags: tree.flags(of: node),
                allocated: bytes, logical: 0, identity: tree.identity(of: node)
            )
        }
        preview.finalizeTotals()
        return preview
    }

    /// The root's child that holds `node`.
    private func topLevel(of node: Int) -> Int {
        tree.topLevelAncestor(of: node)
    }

    func flag(_ folder: Int32, _ flags: NodeFlags) {
        tree.insertFlags(flags, at: Int(folder))
    }

    private func add(_ entry: BulkEntry, of listing: Listing, under parent: Int) -> Int {
        let flags = flags(of: entry, listing: listing)
        let countsBytes = !entry.isDirectory && !flags.contains(.dataless) && entry.error == 0
        let allocated = countsBytes ? entry.allocated : 0
        bytesVisited += allocated
        return listing.names.withUnsafeBufferPointer { names in
            tree.addChild(
                of: parent,
                nameBytes: UnsafeBufferPointer(rebasing: names[entry.nameStart..<entry.nameStart + entry.nameLength]),
                flags: flags,
                allocated: allocated,
                logical: countsBytes ? entry.logical : 0,
                identity: FileIdentity(device: entry.device, inode: entry.inode)
            )
        }
    }

    private func flags(of entry: BulkEntry, listing: Listing) -> NodeFlags {
        guard entry.error == 0 else { return .incomplete }
        var flags: NodeFlags = []
        if entry.isDirectory {
            flags.insert(.directory)
            if entry.mountStatus != 0 { flags.insert(.mountPoint) }
            if isPackage(listing.name(of: entry)) { flags.insert(.package) }
        } else if entry.linkCount > 1 {
            flags.insert(.hardLinked)
        }
        if entry.isSymlink { flags.insert(.symlink) }
        if entry.isDataless { flags.insert(.dataless) }
        if entry.fileFlags & UInt32(UF_COMPRESSED) != 0 { flags.insert(.compressed) }
        if entry.fileFlags & UInt32(SF_RESTRICTED) != 0 { flags.insert(.systemProtected) }
        return flags
    }

    /// Finder's rule: a folder is a package when its extension's type conforms to com.apple.package.
    private func isPackage(_ name: ArraySlice<UInt8>) -> Bool {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > name.startIndex, dot < name.endIndex - 1 else { return false }
        let pathExtension = String(decoding: name[(dot + 1)...], as: UTF8.self).lowercased()
        if let known = packageExtensions[pathExtension] { return known }
        // conformingTo: .directory, or the lookup assumes a data file and misses every bundle type.
        let result = UTType(filenameExtension: pathExtension, conformingTo: .directory)?.conforms(to: .package) ?? false
        packageExtensions[pathExtension] = result
        return result
    }

    /// Firmlinked Data-volume entries go under "/" (Users, Applications, System/Library/Caches via
    /// "System", ...). Everything else on the Data volume root (macOS Install Data, .Spotlight-V100) has
    /// no firmlink and goes under a "System/Volumes/Data" chain, so every path in the tree exists (F-0005).
    private func addDataVolumeRoot(_ listing: Listing, layout: DataVolumeLayout, walkableNodes: inout [Int32]) {
        var nodes = [Int](repeating: -1, count: listing.entries.count)
        var system: Int?
        for (index, entry) in listing.entries.enumerated() where layout.isFirmlinked(listing.name(of: entry)) {
            nodes[index] = add(entry, of: listing, under: ScanTree.root)
            if listing.name(of: entry).elementsEqual("System".utf8) { system = nodes[index] }
        }
        let systemNode = system ?? tree.addChild(of: ScanTree.root, name: "System", flags: .directory, allocated: 0, logical: 0, identity: layout.systemIdentity)
        let volumes = tree.addChild(of: systemNode, name: "Volumes", flags: .directory, allocated: 0, logical: 0, identity: layout.volumesIdentity)
        let data = tree.addChild(of: volumes, name: "Data", flags: .directory, allocated: 0, logical: 0, identity: layout.dataIdentity)
        let before = bytesVisited
        for (index, entry) in listing.entries.enumerated() where nodes[index] < 0 {
            nodes[index] = add(entry, of: listing, under: data)
        }
        bytesUnderTopLevel[systemNode, default: 0] += bytesVisited - before
        for (index, entry) in listing.entries.enumerated() where entry.isWalkable {
            walkableNodes.append(Int32(nodes[index]))
        }
    }
}

/// How the boot volume group maps onto "/" (topic-size-accounting facts 5, 18, 21).
struct DataVolumeLayout {
    static let dataRoot = "/System/Volumes/Data"

    /// First components of the Data-volume side of /usr/share/firmlinks.
    let firmlinkedNames: Set<[UInt8]>
    let rootIdentity: FileIdentity
    let systemIdentity: FileIdentity
    let volumesIdentity: FileIdentity
    let dataIdentity: FileIdentity

    /// nil when this Mac has no separate Data volume.
    init?(firmlinks: String = (try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)) ?? "") {
        guard let root = FileIdentity(url: URL(fileURLWithPath: "/")),
              let system = FileIdentity(url: URL(fileURLWithPath: "/System")),
              let volumes = FileIdentity(url: URL(fileURLWithPath: "/System/Volumes")),
              let data = FileIdentity(url: URL(fileURLWithPath: Self.dataRoot)) else { return nil }
        rootIdentity = root
        systemIdentity = system
        volumesIdentity = volumes
        dataIdentity = data
        firmlinkedNames = Set(firmlinks.split(separator: "\n").compactMap { line in
            let target = line.split(separator: "\t").dropFirst().first
            return target?.split(separator: "/").first.map { Array($0.utf8) }
        })
    }

    /// The layout when a resolved scan root is the startup disk. The app's Macintosh HD scope passes the
    /// Data volume, a user may pick "/"; both mean the same tree.
    static func forStartupDisk(_ path: String) -> DataVolumeLayout? {
        path == "/" || path == dataRoot ? DataVolumeLayout() : nil
    }

    func isFirmlinked(_ name: ArraySlice<UInt8>) -> Bool { firmlinkedNames.contains(Array(name)) }
}

private extension ScanTree {
    /// The root's child that holds `node`. A method on the tree, so a walk up reads the sink's stored
    /// property once: reading it per parent took 561 ms for 150k listings at depth 12, this takes 90 ms.
    func topLevelAncestor(of node: Int) -> Int {
        var top = node
        while let parent = parent(of: top), parent != ScanTree.root { top = parent }
        return top
    }
}
