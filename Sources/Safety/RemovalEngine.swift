import Darwin
import Foundation
import MacontrolCore

/// The permanent remover (DESIGN-debloat section 2.3). Fd-relative, depth first, one thread: it opens no path through
/// a link, checks the item's identity on the descriptor it works through, never leaves the item's volume, never lists
/// an evicted iCloud folder, reads a folder's names before it removes any, and goes on past a failed entry, recording
/// each. Never `removefile` (as root it clears the Locked flag, and it walks by full path), `FileManager`'s remove,
/// `rm`, or a flag, mode or owner change (section 2.3 step 5; the sink audit enforces it).
///
/// Only `O_NOFOLLOW[_ANY]`, `openat` and `unlinkat(AT_REMOVEDIR)` are relied on: all exist on macOS 14.
// ponytail: single thread, one descriptor per depth level. Parallel subtrees (about 2x on 150k entries) when a
// measured delete feels slow; a tree deeper than the descriptor limit reports EMFILE for what is left, which stays in
// the Trash.
struct RemovalEngine: Sendable {
    struct Failure: Sendable, Hashable {
        /// Relative to the item; empty for the item itself.
        var path: String
        var reason: String
    }

    enum Result: Sendable, Hashable {
        case removed
        /// A link on the way, or the object at the path is not the one checked: nothing was removed.
        case changed
        /// These entries stayed. For `deleteFile`, nothing was removed.
        case failed([Failure])
    }

    /// Tests only: called with the item's path and "" before the item is opened, then with each entry's path inside
    /// the item after its `fstatat` and before it is opened or removed. Where a test changes the disk mid-walk.
    var beforeEntry: (@Sendable (_ item: String, _ relative: String) -> Void)?

    init(beforeEntry: (@Sendable (_ item: String, _ relative: String) -> Void)? = nil) {
        self.beforeEntry = beforeEntry
    }

    /// A non-folder at its own place (steps 1-3): one `unlinkat` in its folder, opened with no link anywhere on the
    /// way, and only when the entry there is still `identity`.
    func deleteFile(canonical path: String, identity: FileIdentity) -> Result {
        let (folder, name) = Self.split(path)
        beforeEntry?(path, "")
        let parent = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { return .changed }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, Self.identity(info) == identity,
              info.st_mode & S_IFMT != S_IFDIR else { return .changed }
        var flags: Int32 = 0
        // macOS 26 refuses a file some process holds open; 14 and 15 reject the flag (feasibility-permanent fact 9).
        if #available(macOS 26, *) { flags |= AT_NODELETEBUSY }
        guard unlinkat(parent, name, flags) == 0 else { return .failed([Failure(path: "", reason: Self.describe(errno))]) }
        return .removed
    }

    /// A folder the Trash sink has just moved (steps 1, 2 and 4): reached through its Trash folder with no link on
    /// the way, checked to be `identity` before and after it is opened, emptied, then removed. The protection policy
    /// is not applied again: it would refuse the Trash, and the item passed it at its original place.
    func erase(trashed: URL, identity: FileIdentity) -> Result {
        let path = trashed.path
        let (folder, name) = Self.split(path)
        beforeEntry?(path, "")
        let parent = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { return .changed }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, Self.identity(info) == identity else { return .changed }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .changed }
        var opened = stat()
        guard fstat(fd, &opened) == 0, Self.identity(opened) == identity else {
            close(fd)
            return .changed
        }
        var failures: [Failure] = []
        empty(fd, device: opened.st_dev, item: path, prefix: "", failures: &failures)
        if unlinkat(parent, name, AT_REMOVEDIR) != 0, failures.isEmpty {
            failures.append(Failure(path: "", reason: Self.describe(errno)))
        }
        return failures.isEmpty ? .removed : .failed(failures)
    }

    /// Removes everything inside the folder `fd`, which it closes.
    private func empty(_ fd: Int32, device: dev_t, item: String, prefix: String, failures: inout [Failure]) {
        defer { close(fd) }
        // Every name first: whether a listing still returns every entry once some are removed is unspecified.
        guard let names = Self.names(in: fd) else {
            failures.append(Failure(path: prefix, reason: Self.describe(errno)))
            return
        }
        for name in names {
            let relative = prefix + Self.string(name)
            func fail(_ reason: String) { failures.append(Failure(path: relative, reason: reason)) }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { fail(Self.describe(errno)) }
                continue
            }
            beforeEntry?(item, relative)
            guard info.st_mode & S_IFMT == S_IFDIR else {
                if unlinkat(fd, name, 0) != 0, errno != ENOENT { fail(Self.describe(errno)) }
                continue
            }
            if info.st_dev != device {
                fail(Self.describe(EXDEV))
                continue
            }
            if info.st_flags & UInt32(SF_DATALESS) != 0 {
                fail("It is in iCloud and not downloaded")
                continue
            }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else {
                let code = errno
                // Swapped for a link or a file since the fstatat: that entry goes, never what a link points to.
                if code != ELOOP && code != ENOTDIR {
                    fail(Self.describe(code))
                } else if unlinkat(fd, name, 0) != 0 {
                    fail(Self.describe(errno))
                }
                continue
            }
            var opened = stat()
            guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                close(child)
                fail("It changed while it was being deleted")
                continue
            }
            let before = failures.count
            empty(child, device: device, item: item, prefix: relative + "/", failures: &failures)
            if unlinkat(fd, name, AT_REMOVEDIR) != 0, failures.count == before { fail(Self.describe(errno)) }
        }
    }

    // MARK: Names

    /// Every entry of the folder `fd` except `.` and `..`, as C strings. `fd` stays open and usable.
    static func names(in fd: Int32) -> [[CChar]]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let listing = fdopendir(copy) else {
            close(copy)
            return nil
        }
        defer { closedir(listing) }
        var names: [[CChar]] = []
        while let entry = readdir(listing) {
            let name = name(of: entry)
            if !isDotOrDotDot(name) { names.append(name) }
        }
        return names
    }

    /// The entry's name, NUL-terminated, byte for byte (a name need not be valid UTF-8 on every volume).
    static func name(of entry: UnsafeMutablePointer<dirent>) -> [CChar] {
        withUnsafeBytes(of: entry.pointee.d_name) { $0.prefix(Int(entry.pointee.d_namlen)).map { CChar(bitPattern: $0) } } + [0]
    }

    static func isDotOrDotDot(_ name: [CChar]) -> Bool {
        name == [0x2E, 0] || name == [0x2E, 0x2E, 0]
    }

    /// For messages only.
    static func string(_ name: [CChar]) -> String {
        String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func split(_ path: String) -> (folder: String, name: String) {
        ((path as NSString).deletingLastPathComponent, (path as NSString).lastPathComponent)
    }

    private static func identity(_ info: stat) -> FileIdentity {
        FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
