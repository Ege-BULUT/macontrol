import Darwin
import Foundation

/// Where macontrol refuses to delete, checked before any button is enabled and again at delete time.
///
/// Paths are compared in canonical form, so a symlinked parent, a `..` segment or the
/// `/System/Volumes/Data` spelling of a folder all name the folder they actually reach (F-0039).
/// Locations are matched by containment, not equality (F-0024). Flags and ownership are only read:
/// nothing here, or anywhere in macontrol, changes them to force a delete (F-0070).
public enum ProtectedPaths {
    public static func refusal(
        for url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        cloudConfirmed: Bool = false
    ) -> RefusalReason? {
        do {
            return policy(home).refusal(canonical: try canonicalPath(of: url), cloudConfirmed: cloudConfirmed)
        } catch {
            return error
        }
    }

    /// Why this item goes to the Trash even when the batch deletes permanently (DESIGN-debloat D4), for the
    /// confirmation sheet: "stored in iCloud", "holds your notes"... Nil when it can be deleted. A folder that turns
    /// out to hold an evicted iCloud folder goes to the Trash too, which only the delete itself can see.
    public static func trashOnlyReason(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let path = try? canonicalPath(of: url) else { return nil }
        return policy(home).trashOnlyReason(canonical: path)
    }

    private static func policy(_ home: URL) -> ProtectionPolicy {
        home.path == defaultHome.path ? defaultPolicy : ProtectionPolicy(home: home, journal: TrashService.defaultJournalURL)
    }

    // Built once: callers check every row, and building reads /usr/share/firmlinks.
    private static let defaultHome = FileManager.default.homeDirectoryForCurrentUser
    private static let defaultPolicy = ProtectionPolicy(home: defaultHome, journal: TrashService.defaultJournalURL)

    /// Permission errors and paths past PATH_MAX mean the item may well exist, just out of reach.
    static func unreachable(_ code: Int32) -> RefusalReason {
        code == EACCES || code == EPERM || code == ENAMETOOLONG ? .needsAdministrator : .missing
    }

    /// The kernel's path for `url`: the parent folder resolved with `F_GETPATH` (`realpath` keeps
    /// the Data-volume spelling), plus the last component under its on-disk name. A symlink at the
    /// leaf stays the leaf, because moving it to the Trash moves the link, not what it points to.
    static func canonicalPath(of url: URL) throws(RefusalReason) -> String {
        let path = url.path
        guard path.hasPrefix("/"), !path.contains("\0") else { throw .missing }
        guard path != "/" else { return "/" }
        let slash = path.lastIndex(of: "/")!
        let leaf = String(path[path.index(after: slash)...])
        let resolvesItself = leaf.isEmpty || leaf == "." || leaf == ".."
        let folder = resolvesItself ? path : (slash == path.startIndex ? "/" : String(path[..<slash]))

        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw unreachable(errno) }
        defer { close(fd) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { throw .missing }
        let resolved = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if resolvesItself { return resolved }
        let name = storedName(of: leaf, in: fd) ?? leaf
        return resolved == "/" ? "/" + name : resolved + "/" + name
    }

    /// The name on disk: APFS finds `report.pdf` as `REPORT.PDF`, and Undo must put back `report.pdf`.
    /// Nil when the item does not exist.
    private static func storedName(of leaf: String, in folder: Int32) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_NAME)
        // A length word, then an attrreference_t whose offset counts from itself, then the name.
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<attrreference_t>.size + 1024)
        guard getattrlistat(folder, leaf, &request, &buffer, buffer.count, UInt(FSOPT_NOFOLLOW)) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let reference = raw.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let bytes = raw.dropFirst(4 + Int(reference.attr_dataoffset)).prefix(Int(reference.attr_length))
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Why a folder cannot go whole (`ProtectionPolicy.removalBlocker(inside:forErase:)`).
enum RemovalBlocker: Equatable {
    case refused(RefusalReason)
    /// It holds an evicted iCloud file or folder: it may go to the Trash, but is never emptied (DESIGN-debloat D4).
    case dataless
}

/// The protected-path rules for one home folder, built once per batch. The undo journal's folder is
/// protected too: trashing it would take Undo away from every earlier batch.
struct ProtectionPolicy: Sendable {
    /// Lowercased: APFS is case-insensitive by default, and a false refusal is the safe mistake.
    private let rootsAndTheirAncestors: Set<String>
    private let neverTouch: Set<String>
    private let cloud: [String]
    private let trashOnly: [(path: String, reason: String)]

    /// No defaults: the administrator helper builds this for the requesting user, never for root (r2: sec 6).
    init(home: URL, journal: URL) {
        let home = (try? ProtectedPaths.canonicalPath(of: home)) ?? home.path
        let journalFolder = journal.deletingLastPathComponent()
        let ownState = (try? ProtectedPaths.canonicalPath(of: journalFolder)) ?? journalFolder.path
        let inHome = { (relative: String) in home + "/" + relative }
        let firmlinks = (try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8))?
            .split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) } ?? []

        let roots = ProtectedLocations.systemRoots + firmlinks + [home, ownState] + ProtectedLocations.homeRoots.map(inHome)
        var closure = Set<String>()
        for root in roots {
            var path = root.lowercased()
            while closure.insert(path).inserted, path != "/" {
                path = (path as NSString).deletingLastPathComponent
            }
        }
        rootsAndTheirAncestors = closure
        let neverTouchPaths = ProtectedLocations.systemNeverTouch + ProtectedLocations.homeNeverTouch.map(inHome) + [ownState]
        neverTouch = Set(neverTouchPaths.map { $0.lowercased() })
        cloud = ProtectedLocations.homeCloud.map { inHome($0).lowercased() }
        trashOnly = ProtectedLocations.trashOnly.map { (inHome($0.path).lowercased(), $0.reason) }
    }

    func refusal(canonical path: String, cloudConfirmed: Bool) -> RefusalReason? {
        if let location = protectedLocation(path) { return .protectedLocation(location) }

        let folder = (path as NSString).deletingLastPathComponent
        var item = stat()
        var parent = stat()
        guard lstat(path, &item) == 0 else { return ProtectedPaths.unreachable(errno) }
        guard lstat(folder, &parent) == 0 else { return ProtectedPaths.unreachable(errno) }
        // A mount point or firmlink root lives on another volume than the folder it appears in.
        if item.st_dev != parent.st_dev { return .protectedLocation(path) }
        if let volume = Self.mountPoint(inside: path) { return .protectedLocation(volume) }

        if let reason = Self.flagRefusal(item: item.st_flags, parent: parent.st_flags) { return reason }
        if Self.isReadOnlyVolume(folder) || Self.hasRootlessAttribute(path) { return .systemProtected }
        if !cloudConfirmed && isInCloud(path) { return .needsCloudConfirmation }
        if !Self.canMove(path, item: item, from: folder, parent: parent) { return .needsAdministrator }
        return nil
    }

    /// The item is a protected root or contains one, or lies inside a never-touch area.
    private func protectedLocation(_ path: String) -> String? {
        let lowered = path.lowercased()
        if rootsAndTheirAncestors.contains(lowered) { return path }
        // Each provider's own folder is a root too: all of iCloud Drive, an app's container, a CloudStorage domain.
        if cloud.contains((lowered as NSString).deletingLastPathComponent) { return path }

        let components = path.split(separator: "/")
        // Every other user's home, and /Users/Shared itself.
        if components.count == 2 && components[0].lowercased() == "users" { return path }
        let insideUsrLocal = lowered == "/usr/local" || lowered.hasPrefix("/usr/local/")
        var ancestor = ""
        for component in components {
            ancestor += "/" + component
            let key = ancestor.lowercased()
            if neverTouch.contains(key) && !(key == "/usr" && insideUsrLocal) { return ancestor }
            let name = component.lowercased()
            if ProtectedLocations.neverTouchNames.contains(name) { return ancestor }
            if ProtectedLocations.neverTouchExtensions.contains((name as NSString).pathExtension) { return ancestor }
        }
        return nil
    }

    /// Why a permanent delete moves this item to the Trash instead: it is in the cloud, or it equals, holds or lies
    /// inside one of the personal databases of `ProtectedLocations.trashOnly`.
    func trashOnlyReason(canonical path: String) -> String? {
        let lowered = path.lowercased()
        if isInCloud(path) {
            return lowered.contains("com~apple~") || lowered.contains("/library/mobile documents") ? "stored in iCloud" : "stored in a cloud folder"
        }
        let related = trashOnly.first { lowered == $0.path || lowered.hasPrefix($0.path + "/") || $0.path.hasPrefix(lowered + "/") }
        return related?.reason
    }

    private func isInCloud(_ path: String) -> Bool {
        let lowered = path.lowercased()
        // Provider folders like `com~apple~CloudDocs` mark iCloud wherever they surface.
        return lowered.contains("com~apple~") || cloud.contains { lowered == $0 || lowered.hasPrefix($0 + "/") }
    }

    // SF_RESTRICTED and SF_NOUNLINK are not exported to Swift.
    private static let restricted: UInt32 = 0x0008_0000
    private static let noUnlink: UInt32 = 0x0010_0000

    /// Finder's Locked checkbox, and the append-only flag a user can set the same way.
    private static let userLock = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)
    /// Anything inside a folder with one of these stops the folder: SIP, or flags only root can set.
    private static let systemFlags = restricted | noUnlink | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND)

    /// `sunlnk` protects only the item itself: /Applications has it, and its apps can still go.
    private static func flagRefusal(item: UInt32, parent: UInt32) -> RefusalReason? {
        let system = restricted | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND)
        if item & (system | noUnlink) != 0 || parent & system != 0 { return .systemProtected }
        if item & userLock != 0 || parent & userLock != 0 { return .locked }
        return nil
    }

    /// What stops the folder at `path` from going whole, found by one walk of everything inside it, or nil. A locked
    /// entry (`holdsLocked`, with its path relative to the folder), a system-protected one, a folder on another volume
    /// stop it in both modes. With `forErase` (a permanent delete empties every folder inside), a folder this process
    /// cannot write needs the administrator. An evicted iCloud folder is never listed (listing downloads it, F-0019):
    /// it makes the item go to the Trash instead. Only checked right before the sink, never while staging.
    static func removalBlocker(inside path: String, forErase: Bool) -> RemovalBlocker? {
        let folder = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return nil }
        var info = stat()
        guard fstat(folder, &info) == 0 else {
            close(folder)
            return nil
        }
        if info.st_flags & UInt32(SF_DATALESS) != 0 {
            close(folder)
            return .dataless
        }
        var walk = BlockerWalk(base: path, device: info.st_dev, forErase: forErase)
        if let reason = walk.check(folder, prefix: "") { return .refused(reason) }
        if walk.sawDataless { return .dataless }
        return walk.sawUnwritable ? .refused(.needsAdministrator) : nil
    }

    /// Fd-relative, no link followed, so a tree deeper than PATH_MAX is covered too; it never leaves the folder's volume.
    // ponytail: one fstatat per entry; getattrlistbulk (as ScanEngine's BulkReader) if big folders make it slow.
    private struct BlockerWalk {
        let base: String
        let device: dev_t
        let forErase: Bool
        var sawDataless = false
        var sawUnwritable = false

        /// The first refusal inside `fd`, which it takes ownership of.
        mutating func check(_ fd: Int32, prefix: String) -> RefusalReason? {
            if forErase && faccessat(fd, ".", W_OK, AT_EACCESS) != 0 { sawUnwritable = true }
            guard let listing = fdopendir(fd) else {
                close(fd)
                return nil
            }
            defer { closedir(listing) }
            let folder = dirfd(listing)
            while let entry = readdir(listing) {
                let name = RemovalEngine.name(of: entry)
                if RemovalEngine.isDotOrDotDot(name) { continue }
                let relative = prefix + RemovalEngine.string(name)
                var info = stat()
                guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if info.st_flags & ProtectionPolicy.userLock != 0 { return .holdsLocked(relative) }
                if info.st_flags & ProtectionPolicy.systemFlags != 0 { return .systemProtected }
                let isDataless = info.st_flags & UInt32(SF_DATALESS) != 0
                guard info.st_mode & S_IFMT == S_IFDIR, !isDataless else {
                    sawDataless = sawDataless || isDataless
                    continue
                }
                if info.st_dev != device { return .protectedLocation(base + "/" + relative) }
                let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    // An unreadable folder cannot be emptied. A folder swapped for a link since the fstatat is left to
                    // the sink's own checks.
                    if forErase && (errno == EACCES || errno == EPERM) { sawUnwritable = true }
                    continue
                }
                if let reason = check(child, prefix: relative + "/") { return reason }
            }
            return nil
        }
    }

    /// A volume mounted below `path` (a disk image, an SMB or sshfs mount): moving the folder would
    /// carry the live volume into the Trash, where emptying it reaches the volume's files.
    private static func mountPoint(inside path: String) -> String? {
        let prefix = path.lowercased() + "/"
        var mounts = Array(repeating: statfs(), count: Int(max(getfsstat(nil, 0, MNT_NOWAIT), 0)) + 8)
        let count = getfsstat(&mounts, Int32(mounts.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard count >= 0 else { return path } // No mount table: refuse rather than guess.
        for mount in mounts.prefix(Int(count)) {
            let name = withUnsafeBytes(of: mount.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name.lowercased().hasPrefix(prefix) { return name }
        }
        return nil
    }

    private static func isReadOnlyVolume(_ folder: String) -> Bool {
        var volume = statfs()
        return statfs(folder, &volume) == 0 && volume.f_flags & UInt32(MNT_RDONLY) != 0
    }

    private static func hasRootlessAttribute(_ path: String) -> Bool {
        getxattr(path, "com.apple.rootless", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// What rename(2) needs: write access to the folder, to a moved folder itself (its `..` entry
    /// changes), and ownership of the item or the folder when the folder is sticky.
    private static func canMove(_ path: String, item: stat, from folder: String, parent: stat) -> Bool {
        guard access(folder, W_OK) == 0 else { return false }
        if item.st_mode & S_IFMT == S_IFDIR && access(path, W_OK) != 0 { return false }
        let user = geteuid()
        if parent.st_mode & S_ISVTX != 0 && item.st_uid != user && parent.st_uid != user { return false }
        return true
    }
}
