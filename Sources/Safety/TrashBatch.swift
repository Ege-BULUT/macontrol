import Darwin
import Foundation
import MacontrolCore

/// One `moveToTrash` call. Per item, in order: leave it if the batch keeps it, skip it if a selected
/// ancestor already went (F-0050), apply the protected-path policy, check that no link leads elsewhere on the
/// way, re-check its identity, trash around kept descendants, journal.
struct TrashBatch {
    let id: UUID
    let policy: ProtectionPolicy
    let backend: TrashBackend
    let journal: FileHandle
    let cloudConfirmed: Bool
    /// Canonical path of every item trashed so far, lowercased as the policy compares them, and where it went.
    private var trashed: [String: URL] = [:]
    /// Set when a journal line could not be written: nothing more is trashed without an undo record.
    private var journalError: String?
    /// Every item's `keep`, canonical and lowercased: an unchecked path stays whichever item covers it (F-0026).
    private var keep: Set<String> = []

    init(id: UUID, policy: ProtectionPolicy, backend: TrashBackend, journal: FileHandle, cloudConfirmed: Bool) {
        self.id = id
        self.policy = policy
        self.backend = backend
        self.journal = journal
        self.cloudConfirmed = cloudConfirmed
    }

    mutating func process(_ items: [TrashItem]) -> [TrashOutcome] {
        // Fail closed: a kept path we cannot resolve may well lie inside any item.
        guard let keep = try? Set(items.flatMap(\.keep).map({ try ProtectedPaths.canonicalPath(of: $0).lowercased() })) else {
            return items.map { .failed($0.url, message: "An item you chose to keep could not be checked, so nothing was moved.") }
        }
        self.keep = keep
        let canonical = items.map { item in Result { () throws(RefusalReason) in try ProtectedPaths.canonicalPath(of: item.url) } }
        // Shallowest first, so a folder goes before anything selected inside it.
        let order = items.indices.sorted { depth(canonical[$0]) < depth(canonical[$1]) }
        var outcomes = [[TrashOutcome]](repeating: [], count: items.count)
        for index in order {
            switch canonical[index] {
            case .success(let path): outcomes[index] = process(items[index], canonical: path)
            case .failure(let reason): outcomes[index] = [.refused(items[index].url, reason)]
            }
        }
        return outcomes.flatMap { $0 }
    }

    private mutating func process(_ item: TrashItem, canonical path: String) -> [TrashOutcome] {
        let lowered = path.lowercased()
        if isKept(lowered) { return [.failed(item.url, message: "You chose to keep this, so it was not moved.")] }
        if let destination = trashedAncestor(of: path) {
            return [.trashed(original: item.url, trashedTo: destination)]
        }
        if let reason = policy.refusal(canonical: path, cloudConfirmed: cloudConfirmed) { return [.refused(item.url, reason)] }
        // A folder on the way that became a link since the scan leads somewhere else, even where the object there
        // passes the identity check below, as a hard link of the scanned file does (T-0054).
        guard Self.samePlace(item.url.path, path) else { return [.refused(item.url, .identityChanged)] }
        guard let identity = FileIdentity(url: URL(fileURLWithPath: path)) else { return [.refused(item.url, .missing)] }
        if let expected = item.expectedIdentity, expected != identity { return [.refused(item.url, .identityChanged)] }

        let inside = keep.filter { $0.hasPrefix(lowered + "/") }
        if inside.isEmpty { return [trash(item.url, canonical: path, identity: identity, allocated: item.allocated)] }
        let pieces = trashKeeping(inside, in: path, shownAs: item.url)
        // Callers match outcomes to items by URL, so an item with no piece moved reports itself.
        let accounted = pieces.contains { if case .trashed = $0 { true } else { $0.url == item.url } }
        return accounted ? pieces : pieces + [.failed(item.url, message: "Nothing in it was moved: everything left in it is kept or refused.")]
    }

    /// Trashes everything in `folder` except the kept paths, descending only into folders that hold one (F-0026).
    /// `keep` is lowercased: APFS matches names without case, so `OLD/src` must keep `old/src`.
    private mutating func trashKeeping(_ keep: Set<String>, in folder: String, shownAs shown: URL) -> [TrashOutcome] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            return [.failed(shown, message: "The folder could not be read.")]
        }
        var outcomes: [TrashOutcome] = []
        for name in names.sorted() {
            let child = folder + "/" + name
            let childShown = shown.appendingPathComponent(name)
            let key = child.lowercased()
            if keep.contains(key) { continue }
            if keep.contains(where: { $0.hasPrefix(key + "/") }) && Self.isRealFolder(child) {
                outcomes += trashKeeping(keep, in: child, shownAs: childShown)
            } else if let reason = policy.refusal(canonical: child, cloudConfirmed: cloudConfirmed) {
                outcomes.append(.refused(childShown, reason))
            } else if let identity = FileIdentity(url: URL(fileURLWithPath: child)) {
                outcomes.append(trash(childShown, canonical: child, identity: identity, allocated: Self.fileSize(child)))
            } else {
                outcomes.append(.refused(childShown, .missing))
            }
        }
        return outcomes
    }

    private mutating func trash(_ shown: URL, canonical path: String, identity: FileIdentity, allocated: UInt64) -> TrashOutcome {
        if let journalError { return .failed(shown, message: journalError) }
        if let locked = ProtectionPolicy.lockedItem(inside: path) { return .refused(shown, .holdsLocked(locked)) }
        // The backend moves by path, and a path follows any link swapped in for one of its folders. So check the
        // way just before the move, and after it check that what left is what was checked (T-0053).
        let folder = (path as NSString).deletingLastPathComponent
        guard let before = Self.linkFreeIdentity(of: folder), FileIdentity(url: URL(fileURLWithPath: path)) == identity else {
            return .refused(shown, .identityChanged)
        }
        let destination: URL
        do {
            destination = try backend.moveToTrash(URL(fileURLWithPath: path))
        } catch {
            return .failed(shown, message: error.localizedDescription)
        }
        guard FileIdentity(url: destination) == identity, Self.linkFreeIdentity(of: folder) == before else {
            return putBack(destination, movedFrom: path, shownAs: shown, checked: identity)
        }
        trashed[path.lowercased()] = destination
        record(original: path, trashedTo: destination, identity: identity, allocated: allocated)
        return .trashed(original: shown, trashedTo: destination)
    }

    /// The move went through a link swapped in on the way, so something else reached the Trash. It goes back where
    /// it came from, which the path still leads to; if that fails it is journaled, so Undo can put it back.
    private mutating func putBack(_ destination: URL, movedFrom path: String, shownAs shown: URL, checked: FileIdentity) -> TrashOutcome {
        let origin = (try? ProtectedPaths.canonicalPath(of: URL(fileURLWithPath: path))) ?? path
        if renamex_np(destination.path, origin, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 {
            return .refused(shown, .identityChanged)
        }
        record(original: origin, trashedTo: destination, identity: FileIdentity(url: destination) ?? checked, allocated: 0)
        return .failed(shown, message: "It changed as it moved, and what reached the Trash instead could not be put back. Undo it from History.")
    }

    private mutating func record(original path: String, trashedTo destination: URL, identity: FileIdentity, allocated: UInt64) {
        let entry = JournalEntry(
            batch: id, date: Date(), originalPath: path, trashedPath: destination.path,
            identity: identity, allocated: allocated, restored: false
        )
        do {
            try TrashJournal.append(entry, to: journal)
        } catch {
            journalError = "Stopped: the undo journal could not be written (\(error.localizedDescription))."
        }
    }

    /// The path, or a folder holding it, was unchecked somewhere in the batch.
    private func isKept(_ lowered: String) -> Bool {
        var path = lowered
        while !keep.contains(path) {
            guard path != "/" else { return false }
            path = (path as NSString).deletingLastPathComponent
        }
        return true
    }

    /// Where `path` went if it, or a folder holding it, was trashed earlier in this batch.
    private func trashedAncestor(of path: String) -> URL? {
        var ancestor = path
        var relative: [String] = []
        while true {
            if let folder = trashed[ancestor.lowercased()] {
                let destination = relative.reduce(folder) { $0.appendingPathComponent($1) }
                // Keys ignore case, so on a case-sensitive volume `Cache` matches `cache`: believe the
                // match only when the item really left its path and is at that place in the Trash.
                return !Self.exists(path) && Self.exists(destination.path) ? destination : nil
            }
            guard ancestor != "/" else { return nil }
            relative.insert((ancestor as NSString).lastPathComponent, at: 0)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }

    /// `named` reaches `canonical` with no link on the way: the two differ only in macOS's own spellings, which are
    /// case, the Data volume's prefix and the root links /var, /tmp and /etc into /private.
    private static func samePlace(_ named: String, _ canonical: String) -> Bool {
        func plain(_ path: String) -> String {
            var path = path.lowercased()
            if path.hasPrefix("/system/volumes/data/") { path.removeFirst("/system/volumes/data".count) }
            if ["/var/", "/tmp/", "/etc/"].contains(where: path.hasPrefix) { path = "/private" + path }
            return path
        }
        // String equality is canonical equivalence, so a composed name matches its decomposed spelling on disk.
        return plain(named) == plain(canonical)
    }

    /// Identity of `folder`, opened without following a link anywhere in its path; nil when a link is on the way.
    private static func linkFreeIdentity(of folder: String) -> FileIdentity? {
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        return fstat(fd, &info) == 0 ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil
    }

    private func depth(_ path: Result<String, RefusalReason>) -> Int {
        (try? path.get())?.split(separator: "/").count ?? 0
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    // ponytail: a folder pieced out by `keep` records 0 B; pass sizes from the scan if History needs them.
    private static func fileSize(_ path: String) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { return 0 }
        return UInt64(info.st_blocks) * 512
    }
}

private extension TrashOutcome {
    var url: URL {
        switch self {
        case .trashed(let url, _), .refused(let url, _), .failed(let url, _): url
        }
    }
}
