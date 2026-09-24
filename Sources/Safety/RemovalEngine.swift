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
        /// Nothing was removed; these are why.
        case failed([Failure])
        /// Some entries were removed; these stayed. Only `erase` returns it.
        case partly([Failure])
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
        guard parent >= 0 else { return Self.notOpened(errno) }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return Self.notOpened(errno) }
        guard Self.identity(info) == identity, info.st_mode & S_IFMT != S_IFDIR else { return .changed }
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
        guard parent >= 0 else { return Self.notOpened(errno) }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return Self.notOpened(errno) }
        guard Self.identity(info) == identity else { return .changed }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return Self.notOpened(errno) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, Self.identity(opened) == identity else {
            close(fd)
            return .changed
        }
        var (failures, removed) = empty(fd, device: opened.st_dev, item: path)
        if unlinkat(parent, name, AT_REMOVEDIR) != 0, failures.isEmpty {
            failures.append(Failure(path: "", reason: Self.describe(errno)))
        }
        if failures.isEmpty { return .removed }
        return removed ? .partly(failures) : .failed(failures)
    }

    /// Why a folder on the way or the item could not be opened: a link or a missing entry means it changed; anything
    /// else (no permission, TCC, too many open files) is a failure with nothing removed.
    private static func notOpened(_ code: Int32) -> Result {
        ProtectionPolicy.unreadable(code) ? .failed([Failure(path: "", reason: describe(code))]) : .changed
    }

    /// One folder being emptied: its descriptor, every name it held when opened, and how far the walk got.
    private struct Level {
        let fd: Int32
        let names: [[CChar]]
        var next = 0
        /// Its path inside the item, with a trailing slash; empty for the item.
        let prefix: String
        /// Its name in the level above; nil for the item.
        let name: [CChar]?
        let failuresBefore: Int
    }

    /// Removes everything inside the folder `fd`, which it closes, and says whether it removed anything. A loop over an
    /// explicit stack, not recursion: the actor's queue thread has a 512 KB stack, which a 300-level tree overflowed.
    private func empty(_ fd: Int32, device: dev_t, item: String) -> (failures: [Failure], removed: Bool) {
        // Every name first: whether a listing still returns every entry once some are removed is unspecified.
        guard let names = Self.names(in: fd) else {
            close(fd)
            return ([Failure(path: "", reason: Self.describe(errno))], false)
        }
        var failures: [Failure] = []
        var removed = false
        /// `unlinkat`, noting a success.
        func remove(_ folder: Int32, _ name: [CChar], _ flags: Int32) -> Bool {
            let done = unlinkat(folder, name, flags) == 0
            removed = removed || done
            return done
        }
        var levels = [Level(fd: fd, names: names, prefix: "", name: nil, failuresBefore: 0)]
        while let level = levels.last {
            guard level.next < level.names.count else {
                // Emptied, as far as it goes: close it and remove it from the level above.
                levels.removeLast()
                close(level.fd)
                if let name = level.name, let above = levels.last, !remove(above.fd, name, AT_REMOVEDIR),
                   failures.count == level.failuresBefore {
                    failures.append(Failure(path: String(level.prefix.dropLast()), reason: Self.describe(errno)))
                }
                continue
            }
            levels[levels.count - 1].next += 1
            let name = level.names[level.next]
            let relative = level.prefix + Self.string(name)
            func fail(_ reason: String) { failures.append(Failure(path: relative, reason: reason)) }
            var info = stat()
            guard fstatat(level.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { fail(Self.describe(errno)) }
                continue
            }
            beforeEntry?(item, relative)
            guard info.st_mode & S_IFMT == S_IFDIR else {
                if !remove(level.fd, name, 0), errno != ENOENT { fail(Self.describe(errno)) }
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
            let child = openat(level.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else {
                let code = errno
                // Swapped for a link or a file since the fstatat: that entry goes, never what a link points to.
                if code != ELOOP && code != ENOTDIR {
                    fail(Self.describe(code))
                } else if !remove(level.fd, name, 0) {
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
            guard let names = Self.names(in: child) else {
                fail(Self.describe(errno))
                close(child)
                continue
            }
            levels.append(Level(fd: child, names: names, prefix: relative + "/", name: name, failuresBefore: failures.count))
        }
        return (failures, removed)
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
