import Darwin
import Foundation
import MacontrolCore

/// The items of a `reclaimable` request, each counted once.
///
/// A folder is one item per identity; a file is one item per (parent folder identity, name), because
/// two links of one inode are two items while a firmlink alias (`/System/Volumes/Data/Users/me/x` next
/// to `~/x`) is the same one (F-0058, F-0039). Items inside another selected folder are dropped.
struct Selection {
    private(set) var folders: [WalkRoot] = []
    /// Selected file names, grouped by the folder that lists them.
    private(set) var filesByParent: [FileIdentity: (path: String, names: Set<String>)] = [:]

    init(_ urls: [URL]) {
        var identities: [String: FileIdentity?] = [:]
        func identity(_ path: String) -> FileIdentity? {
            if let known = identities[path] { return known }
            let found = FileIdentity(url: URL(fileURLWithPath: path))
            identities[path] = found
            return found
        }

        var items: [(path: String, identity: FileIdentity, isFolder: Bool)] = []
        for url in urls {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }  // gone already: frees nothing
            items.append((url.path, FileIdentity(device: info.st_dev, inode: info.st_ino), info.st_mode & S_IFMT == S_IFDIR))
        }
        let folderIdentities = Set(items.filter(\.isFolder).map(\.identity))
        var seenFolders = Set<FileIdentity>()
        for item in items where !Self.isInside(item.path, folderIdentities, identity: identity) {
            if item.isFolder {
                if seenFolders.insert(item.identity).inserted {
                    folders.append(WalkRoot(path: item.path, identity: item.identity, node: 0))
                }
            } else {
                let parentPath = (item.path as NSString).deletingLastPathComponent
                guard let parent = identity(parentPath) else { continue }
                filesByParent[parent, default: (parentPath, [])].names.insert((item.path as NSString).lastPathComponent)
            }
        }
    }

    /// Lists each parent folder once and hands the selected files' entries to `sink`.
    func readFiles(into sink: ReclaimSink) {
        let reader = BulkReader(extended: true)
        var listing = Listing()
        var nodes: [Int32] = []
        for (path, names) in filesByParent.values {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else {
                sink.flag(0, .unreadable)
                continue
            }
            listing.removeAll()
            if reader.read(fd, into: &listing) != 0 { sink.flag(0, .incomplete) }
            close(fd)
            let listed = listing.names
            var missing = names
            listing.entries.removeAll { entry in
                // String equality is canonical, like APFS name lookup: an NFC request matches an NFD name.
                missing.remove(String(decoding: listed[entry.nameStart..<entry.nameStart + entry.nameLength], as: UTF8.self)) == nil
            }
            sink.add(listing, to: 0, walkableNodes: &nodes)
            // Spelled in another case on a case-insensitive volume, or gone since: unknown, never a silent 0.
            if !missing.isEmpty { sink.flag(0, .incomplete) }
        }
    }

    private static func isInside(_ path: String, _ folders: Set<FileIdentity>, identity: (String) -> FileIdentity?) -> Bool {
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor != "/" && !ancestor.isEmpty {
            if let found = identity(ancestor), folders.contains(found) { return true }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return false
    }
}
