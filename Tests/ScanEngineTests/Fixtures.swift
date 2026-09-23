import Darwin
import Foundation
import MacontrolCore
import ScanEngine
import TestSupport

/// Scan helpers and fixtures that need more than `TemporaryDirectory` offers. Everything here writes
/// only inside the temporary directory it is given.
enum Fixtures {
    static func scanTree(_ root: URL, options: ScanOptions = ScanOptions()) async throws -> ScanTree {
        for try await event in ScanEngine(options: options).scan(root) {
            if case .completed(let tree) = event { return tree }
        }
        throw CancellationError()
    }

    static func node(_ path: String, in tree: ScanTree) -> Int? {
        var node = ScanTree.root
        for component in path.split(separator: "/") {
            guard let child = tree.children(of: node).first(where: { tree.name(of: $0) == component }) else { return nil }
            node = child
        }
        return node
    }

    /// Allocated bytes of every folder, keyed by its path below the root.
    static func folderSizes(_ tree: ScanTree) -> [[UInt8]: UInt64] {
        var sizes: [[UInt8]: UInt64] = [:]
        for node in 0..<tree.count where tree.flags(of: node).contains(.directory) {
            sizes[tree.relativePathBytes(of: node)] = tree.allocatedSize(of: node)
        }
        return sizes
    }

    static func allocatedBytes(_ url: URL) -> UInt64 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(info.st_blocks) * 512 : 0
    }

    /// `depth` nested folders named `name` under `parent`, created fd-relative so the chain may be longer
    /// than PATH_MAX, with a file of `fileSize` bytes at the bottom.
    ///
    /// Built in shallow segments that are then moved into place: each mkdir costs the kernel time in
    /// proportion to its depth, so a 4,000-level chain made in place takes over a minute.
    static func makeChain(in parent: URL, name: String, depth: Int, fileSize: Int) throws {
        let segment = 100
        let scratch = open(parent.path, O_RDONLY | O_DIRECTORY)
        var bottom = dup(scratch)
        defer { close(scratch); close(bottom) }
        var built = 0
        while built < depth {
            let levels = min(segment, depth - built)
            guard mkdirat(scratch, "segment", 0o755) == 0 else { throw POSIXError(.EIO) }
            var fd = openat(scratch, "segment", O_RDONLY | O_DIRECTORY)
            for _ in 1..<levels {
                guard fd >= 0, mkdirat(fd, name, 0o755) == 0 else { throw POSIXError(.EIO) }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY)
                close(fd)
                fd = next
            }
            close(fd)
            guard renameat(scratch, "segment", bottom, name) == 0 else { throw POSIXError(.EIO) }
            for _ in 0..<levels {
                let next = openat(bottom, name, O_RDONLY | O_DIRECTORY)
                close(bottom)
                bottom = next
                guard bottom >= 0 else { throw POSIXError(.EIO) }
            }
            built += levels
        }
        let file = openat(bottom, "bottom.bin", O_WRONLY | O_CREAT, 0o644)
        guard file >= 0 else { throw POSIXError(.EIO) }
        let bytes = [UInt8](repeating: 1, count: fileSize)
        _ = bytes.withUnsafeBytes { write(file, $0.baseAddress, fileSize) }
        close(file)
    }

    /// Cuts a chain made by `makeChain` into pieces of `levels` folders, moved to the top of `root`,
    /// so `TemporaryDirectory` can delete it with ordinary path-based calls.
    static func cutChain(in parent: URL, name: String, depth: Int, every levels: Int, root: URL) {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY)
        var fd = open(parent.path, O_RDONLY | O_DIRECTORY)
        defer { close(rootFD) }
        var piece = 0
        for level in 1...depth {
            if level % levels == 0 {
                piece += 1
                let pieceName = "piece-\(piece)"
                guard renameat(fd, name, rootFD, pieceName) == 0 else { break }
                close(fd)
                fd = openat(rootFD, pieceName, O_RDONLY | O_DIRECTORY)
            } else {
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY)
                close(fd)
                fd = next
            }
            if fd < 0 { return }
        }
        close(fd)
    }

    /// A full tree `width` folders wide and `depth` deep, one small file per folder.
    static func makeBushyTree(_ tmp: TemporaryDirectory, under base: String, width: Int, depth: Int) throws -> Int {
        var files = 0
        func grow(_ path: String, _ level: Int) throws {
            try tmp.file("\(path)/f.txt", size: 100)
            files += 1
            guard level < depth else { return }
            for index in 0..<width { try grow("\(path)/d\(index)", level + 1) }
        }
        try grow(base, 0)
        return files
    }
}
