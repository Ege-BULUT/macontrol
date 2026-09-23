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
        for entry in listing.entries {
            let node = add(entry, of: listing, under: Int(folder))
            if entry.isWalkable { walkableNodes.append(Int32(node)) }
        }
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
        for (index, entry) in listing.entries.enumerated() where nodes[index] < 0 {
            nodes[index] = add(entry, of: listing, under: data)
        }
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
