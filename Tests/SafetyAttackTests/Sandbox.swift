import Darwin
import Foundation
import MacontrolCore
import Safety
import TestSupport

/// A fake home, a Trash and an undo journal inside one temporary folder, driven through the real `TrashService`.
///
/// The backend stands in for `FileManager.trashItem`: a path-based rename into the sandbox's Trash, which follows
/// symlinks in the parent folders just as the real one does. It resolves the parent first and refuses anything
/// that would leave the temporary folder, so no attack here can move a file of this Mac.
final class Sandbox: @unchecked Sendable {
    let tmp: TemporaryDirectory
    let home: URL
    let trashFolder: URL
    let journal: URL
    private let lock = NSLock()
    private var moved: [URL] = []
    private var hook: (@Sendable (URL) -> Void)?
    private var deepChains: [(fd: Int32, name: String)] = []

    init() throws {
        tmp = try TemporaryDirectory()
        home = try tmp.directory("home")
        trashFolder = try tmp.directory("Trash")
        journal = tmp.url.appendingPathComponent("state/trash-journal.jsonl")
        for folder in ["Library/Caches", "Library/Application Support", "Library/Preferences", "Library/LaunchAgents", "Documents", ".ssh"] {
            try tmp.directory("home/" + folder)
        }
    }

    deinit {
        for chain in deepChains {
            // Cut each deep chain in two, so both halves are short enough for the temporary folder to remove.
            renameat(chain.fd, chain.name, AT_FDCWD, tmp.url.appendingPathComponent("deep-tail-\(UUID().uuidString)").path)
            close(chain.fd)
        }
        // Locked fixtures would stop the temporary folder from removing itself.
        for (path, entry) in Self.snapshot(of: tmp.url) where entry.flags & UInt32(UF_IMMUTABLE) != 0 {
            lchflags(tmp.url.appendingPathComponent(path).path, entry.flags & ~UInt32(UF_IMMUTABLE))
        }
    }

    /// Runs just before the backend moves each item: where an attack changes the disk mid-batch.
    func beforeEachMove(_ hook: @escaping @Sendable (URL) -> Void) {
        lock.withLock { self.hook = hook }
    }

    var backendCalls: [URL] { lock.withLock { moved } }

    func service() -> TrashService {
        TrashService(journalURL: journal, backend: backend, home: home)
    }

    private var backend: TrashBackend {
        TrashBackend { [self] url in
            lock.withLock { hook }?(url)
            lock.withLock { moved.append(url) }
            let parent = url.deletingLastPathComponent().path
            guard let real = realpath(parent, nil) else { throw CocoaError(.fileNoSuchFile) }
            defer { free(real) }
            guard (String(cString: real) + "/").hasPrefix(tmp.url.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
            let destination = trashFolder.appendingPathComponent(UUID().uuidString).appendingPathComponent(url.lastPathComponent)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    // MARK: Building hostile trees

    func url(_ relative: String) -> URL { tmp.url.appendingPathComponent(relative) }

    @discardableResult
    func file(_ relative: String, size: Int = 4096) throws -> URL {
        try tmp.file(relative, size: size)
    }

    /// Replaces the object at `relative` with a symlink to `destination`, keeping the original next to it:
    /// what an app, a sync client or an attacker can do between a scan and a delete.
    func swapForSymlink(_ relative: String, to destination: URL) throws {
        let original = url(relative)
        try FileManager.default.moveItem(at: original, to: original.deletingLastPathComponent().appendingPathComponent("moved-away-\(UUID().uuidString)"))
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: destination)
    }

    /// A chain of folders under `relative` whose deepest path is longer than PATH_MAX, built fd-relative.
    /// Returns the chain's top folder and the relative path of a file at the bottom.
    func deepChain(_ relative: String, levels: Int = 20) throws -> (top: URL, leaf: String) {
        let top = try tmp.directory(relative)
        let name = String(repeating: "d", count: 60)
        var fd = open(top.path, O_RDONLY | O_DIRECTORY)
        var leaf = relative
        for level in 1...levels {
            guard mkdirat(fd, name, 0o755) == 0 else { throw POSIXError(.EIO) }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY)
            if level == levels / 2 { lock.withLock { deepChains.append((fd, name)) } } else { close(fd) }
            fd = next
            leaf += "/" + name
        }
        let file = openat(fd, "bottom.bin", O_WRONLY | O_CREAT, 0o644)
        _ = write(file, [UInt8](repeating: 7, count: 4096), 4096)
        close(file)
        close(fd)
        return (top, leaf + "/bottom.bin")
    }

    // MARK: Checking what moved

    struct Entry: Hashable {
        var type: mode_t
        var device: Int32
        var inode: UInt64
        /// Files only: a folder's size changes with its entries.
        var size: Int64
        var flags: UInt32
        var linkTarget: String?
    }

    /// Everything in the sandbox except its Trash and journal, by path relative to the sandbox. Walked
    /// fd-relative, never following links, so paths past PATH_MAX are listed too.
    func tree() -> [String: Entry] {
        Self.snapshot(of: tmp.url).filter { path, _ in
            !(path == "Trash" || path.hasPrefix("Trash/") || path == "state" || path.hasPrefix("state/"))
        }
    }

    /// `before` with every path at or under one of `removed` taken out.
    static func expected(_ before: [String: Entry], without removed: [String]) -> [String: Entry] {
        before.filter { path, _ in !removed.contains { path == $0 || path.hasPrefix($0 + "/") } }
    }

    /// Paths whose entry differs between two trees, for readable failures.
    static func difference(_ left: [String: Entry], _ right: [String: Entry]) -> [String] {
        Set(left.keys).union(right.keys).filter { left[$0] != right[$0] }.sorted()
    }

    static func snapshot(of root: URL) -> [String: Entry] {
        var result: [String: Entry] = [:]
        let fd = open(root.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return [:] }
        walk(fd, prefix: "", into: &result)
        close(fd)
        return result
    }

    private static func walk(_ folder: Int32, prefix: String, into result: inout [String: Entry]) {
        guard let listing = fdopendir(dup(folder)) else { return }
        defer { closedir(listing) }
        while let dirent = readdir(listing) {
            let name = withUnsafeBytes(of: dirent.pointee.d_name) { String(decoding: $0.prefix(Int(dirent.pointee.d_namlen)), as: UTF8.self) }
            guard name != ".", name != ".." else { continue }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            var target: String?
            if type == S_IFLNK {
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                let length = readlinkat(folder, name, &buffer, buffer.count)
                target = length >= 0 ? String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            }
            result[path] = Entry(
                type: type, device: info.st_dev, inode: info.st_ino, size: type == S_IFDIR ? 0 : info.st_size,
                flags: info.st_flags, linkTarget: target
            )
            if type == S_IFDIR {
                let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if child >= 0 {
                    walk(child, prefix: path, into: &result)
                    close(child)
                }
            }
        }
    }
}

extension TrashOutcome {
    var isTrashed: Bool {
        if case .trashed = self { true } else { false }
    }

    var refusal: RefusalReason? {
        if case .refused(_, let reason) = self { reason } else { nil }
    }

    var original: URL? {
        if case .trashed(let original, _) = self { original } else { nil }
    }
}

extension RestoreOutcome {
    var isRestored: Bool {
        if case .restored = self { true } else { false }
    }
}

/// Names that break shells, quoting, JSON Lines and eyes. None of them may ever run, split or match another file.
enum HostileNames {
    static let shell = [
        "$(touch PWNED-dollar)", "`touch PWNED-backtick`", "'; touch PWNED-quote; '", "\"; touch PWNED-dq; \"",
        "a & touch PWNED-amp", "-rf", "*", "~", "%d %p %n", "line\nbreak",
        // A whole journal line after a newline (no slash: names cannot hold one).
        "x\n{\"allocated\":0,\"batch\":\"00000000-0000-0000-0000-000000000000\",\"date\":\"2026-01-01T00:00:00Z\",\"identity\":{\"device\":1,\"inode\":2},\"originalPath\":\"\",\"restored\":false,\"trashedPath\":\"\"}",
    ]
    /// `Cache` with a Cyrillic а, next to the Latin one it imitates.
    static let lookalike = "C\u{0430}che"
    /// `café` in decomposed form (e + combining acute).
    static let decomposed = "cafe\u{0301}"
}
