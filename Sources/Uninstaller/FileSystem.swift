import Darwin
import Foundation

/// Small read-only file system helpers shared by the inventory and the leftover search.
enum FileSystem {
    /// Names in a folder, without dot entries. An unreadable or missing folder has no children.
    static func children(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    static func status(of url: URL) -> stat? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info : nil
    }

    /// A real folder: symlinks do not count, so the search never leaves the folder it was given.
    static func isDirectory(_ url: URL) -> Bool {
        status(of: url).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false
    }

    static func exists(_ url: URL) -> Bool { status(of: url) != nil }

    /// Whether this user can move the item to the Trash: its folder must be writable, and a folder itself too,
    /// because moving a folder rewrites its `..` entry.
    static func isRemovableByUser(_ url: URL) -> Bool {
        guard let info = status(of: url), access(url.deletingLastPathComponent().path, W_OK) == 0 else { return false }
        return info.st_mode & S_IFMT != S_IFDIR || access(url.path, W_OK) == 0
    }

    static func propertyList(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}

/// Runs blocking file I/O on a GCD thread, never on the cooperative pool (docs/ARCHITECTURE.md, "Concurrency").
func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}
