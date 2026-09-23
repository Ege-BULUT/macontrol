import Foundation
import MacontrolCore

public struct ScanOptions: Sendable {
    /// Walker threads. `nil` lets the engine pick (active cores, fewer under Low Power Mode or thermal pressure).
    public var workerCount: Int?

    public init(workerCount: Int? = nil) {
        self.workerCount = workerCount
    }
}

public struct ScanProgress: Sendable, Equatable {
    public var filesVisited: Int
    public var bytesVisited: UInt64
    public var currentPath: String?

    public init(filesVisited: Int, bytesVisited: UInt64, currentPath: String?) {
        self.filesVisited = filesVisited
        self.bytesVisited = bytesVisited
        self.currentPath = currentPath
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case completed(ScanTree)
}

/// Every size macontrol shows comes from here.
///
/// PLACEHOLDER (scaffold): a serial FileManager walk with the final API. The M2 engine replaces the
/// bodies with the fd-relative, parallel getattrlistbulk walker in docs/ARCHITECTURE.md.
public final class ScanEngine: Sendable {
    public let options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Streams progress (at most about 10 events a second), then exactly one `.completed` tree.
    /// Ending the stream or cancelling the consumer stops the walk.
    public func scan(_ root: URL) -> AsyncThrowingStream<ScanEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let tree = try PlaceholderWalker(root: root) { continuation.yield(.progress($0)) }.buildTree()
                    continuation.yield(.completed(tree))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sizes of one item without keeping a tree. Used by the cleaner and the uninstaller.
    public func measure(_ url: URL) async throws -> ItemMeasurement {
        try await Task.detached { try PlaceholderWalker(root: url, onProgress: nil).measure() }.value
    }

    /// What trashing `urls` together and emptying the Trash would free right now.
    /// PLACEHOLDER: allocated bytes, which overstates clones (F-0004) until M2 reads ATTR_CMNEXT_PRIVATESIZE.
    public func reclaimable(_ urls: [URL]) async throws -> ReclaimEstimate {
        var total: UInt64 = 0
        for url in urls { total += try await measure(url).allocated }
        return ReclaimEstimate(freesNow: total, sharedElsewhere: 0)
    }
}

enum ScanError: Error {
    case unreadableRoot(URL)
}

private struct PlaceholderWalker {
    let root: URL
    let onProgress: (@Sendable (ScanProgress) -> Void)?
    private let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey,
        .totalFileSizeKey, .linkCountKey, .contentModificationDateKey,
    ]

    init(root: URL, onProgress: (@Sendable (ScanProgress) -> Void)?) {
        self.root = root
        self.onProgress = onProgress
    }

    func buildTree() throws -> ScanTree {
        guard let identity = FileIdentity(url: root) else { throw ScanError.unreadableRoot(root) }
        var tree = ScanTree(rootURL: root, rootIdentity: identity)
        var seenLinks = Set<FileIdentity>()
        var progress = ScanProgress(filesVisited: 0, bytesVisited: 0, currentPath: nil)
        var pending = [(ScanTree.root, root)]
        while let (parent, folder) = pending.popLast() {
            try Task.checkCancellation()
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else {
                tree.insertFlags(.unreadable, at: parent)
                continue
            }
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: Set(keys)), let entryID = FileIdentity(url: entry) else { continue }
                var flags: NodeFlags = []
                var allocated = UInt64(values.totalFileAllocatedSize ?? 0)
                if values.isDirectory == true && values.isSymbolicLink != true { flags.insert(.directory) }
                if values.isSymbolicLink == true { flags.insert(.symlink) }
                if values.isPackage == true { flags.insert(.package) }
                if (values.linkCount ?? 1) > 1 && !flags.contains(.directory) {
                    flags.insert(.hardLinked)
                    if !seenLinks.insert(entryID).inserted {
                        flags.insert(.sharedHardLink)
                        allocated = 0
                    }
                }
                if flags.contains(.directory) && entryID.device != identity.device { flags.insert(.mountPoint) }
                let node = tree.addChild(
                    of: parent, name: entry.lastPathComponent, flags: flags,
                    allocated: allocated, logical: UInt64(values.totalFileSize ?? 0), identity: entryID
                )
                if flags.contains(.directory) && !flags.contains(.mountPoint) { pending.append((node, entry)) }
                progress.filesVisited += 1
                progress.bytesVisited += allocated
            }
            if progress.filesVisited % 2048 < entries.count {
                progress.currentPath = folder.path
                onProgress?(progress)
            }
        }
        tree.finalizeTotals()
        return tree
    }

    func measure() throws -> ItemMeasurement {
        let values = try root.resourceValues(forKeys: Set(keys))
        if values.isDirectory != true || values.isSymbolicLink == true {
            return ItemMeasurement(
                allocated: UInt64(values.totalFileAllocatedSize ?? 0), logical: UInt64(values.totalFileSize ?? 0),
                fileCount: 1, newestModification: values.contentModificationDate, isIncomplete: false
            )
        }
        let tree = try buildTree()
        var newest: Date?
        var incomplete = false
        for index in 0..<tree.count {
            let flags = tree.flags(of: index)
            if flags.contains(.unreadable) { incomplete = true }
            if !flags.contains(.directory),
               let date = try? tree.url(of: index).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date > (newest ?? .distantPast) {
                newest = date
            }
        }
        return ItemMeasurement(
            allocated: tree.allocatedSize(of: ScanTree.root),
            logical: tree.logicalSize(of: ScanTree.root),
            fileCount: tree.fileCount(of: ScanTree.root),
            newestModification: newest,
            isIncomplete: incomplete
        )
    }
}
