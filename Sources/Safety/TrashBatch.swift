import Darwin
import Foundation
import MacontrolCore

/// One Safety batch. Per item, in order: `requiresGone`, leave it if the batch keeps it, skip it if a selected
/// ancestor already went (F-0050), apply the protected-path policy, check that no link leads elsewhere on the way,
/// re-check its identity, then remove it around kept descendants and journal it. `.trash` moves it to the Trash (v1).
/// `.permanent` deletes a file in place, and moves a folder to the Trash first and erases it there, so a stop halfway
/// leaves the rest in the Trash, never a half-deleted folder at its place (DESIGN-debloat D3).
struct TrashBatch {
    let id: UUID
    let policy: ProtectionPolicy
    let backend: TrashBackend
    let journal: FileHandle
    let cloudConfirmed: Bool
    let mode: DeletionMode
    /// Recorded on every journal line of the batch.
    let restorePoint: String?
    let engine: RemovalEngine
    /// Where each item removed so far went, by canonical path lowercased as the policy compares them.
    private var gone: [String: Gone] = [:]
    /// Set when a journal line could not be written: nothing more is removed without a record.
    private var journalError: String?
    /// Every item's `keep`, canonical and lowercased: an unchecked path stays whichever item covers it (F-0026).
    private var keep: Set<String> = []

    private enum Gone {
        case trashed(URL)
        /// Moved to the Trash and erased there, perhaps partly.
        case erased(URL)
        /// A file deleted in place.
        case deleted
    }

    /// Pass 1 of `TrashService.remove` (section 3.6), and what passes 2 and 3 work on.
    struct Passes {
        /// Per item, in the order of the items; an item pieced out by `keep` reports each piece.
        var outcomes: [[TrashOutcome]]
        /// Refused with `.needsAdministrator` and nothing else: for the administrator helper, in item order.
        var setAside: [Int] = []
        /// Their `requiresGone` names a set-aside item: they run after the helper, in pass 3.
        var deferred: [Int] = []
    }

    init(
        id: UUID, policy: ProtectionPolicy, backend: TrashBackend, journal: FileHandle, cloudConfirmed: Bool,
        mode: DeletionMode, restorePoint: String? = nil, engine: RemovalEngine = RemovalEngine()
    ) {
        self.id = id
        self.policy = policy
        self.backend = backend
        self.journal = journal
        self.cloudConfirmed = cloudConfirmed
        self.mode = mode
        self.restorePoint = restorePoint
        self.engine = engine
    }

    /// Pass 1: every item's pre-flight and sink, except the items that wait for a set-aside one.
    mutating func firstPass(_ items: [TrashItem]) -> Passes {
        // Fail closed: a kept path we cannot resolve may well lie inside any item.
        guard let keep = try? Set(items.flatMap(\.keep).map({ try ProtectedPaths.canonicalPath(of: $0).lowercased() })) else {
            let message = "An item you chose to keep could not be checked, so nothing was moved."
            return Passes(outcomes: items.map { [.failed($0.url, message: message)] })
        }
        self.keep = keep
        let canonical = items.map(Self.canonical)
        var passes = Passes(outcomes: Array(repeating: [], count: items.count))
        var waiting = Set<String>()
        for index in Self.order(items, canonical) {
            let item = items[index]
            if let required = item.requiresGone, waiting.contains(Self.key(required)) {
                passes.deferred.append(index)
                waiting.insert(Self.key(item.url))
                continue
            }
            passes.outcomes[index] = process(item, canonical: canonical[index])
            if passes.outcomes[index] == [.refused(item.url, .needsAdministrator)] {
                passes.setAside.append(index)
                waiting.insert(Self.key(item.url))
            }
        }
        passes.setAside.sort()
        return passes
    }

    /// Pass 3: the deferred items, each checking its `requiresGone` again now that the helper has run.
    mutating func lastPass(_ items: [TrashItem], _ passes: inout Passes) {
        let canonical = items.map(Self.canonical)
        for index in Self.order(items, canonical) where passes.deferred.contains(index) {
            passes.outcomes[index] = process(items[index], canonical: canonical[index])
        }
    }

    /// Shallowest first, so a folder goes before anything selected inside it; items that wait for another to be gone
    /// after every item that does not, so an app's bundle goes before its leftovers wherever it lives.
    private static func order(_ items: [TrashItem], _ canonical: [Result<String, RefusalReason>]) -> [Int] {
        func rank(_ index: Int) -> (Int, Int) {
            (items[index].requiresGone == nil ? 0 : 1, (try? canonical[index].get())?.split(separator: "/").count ?? 0)
        }
        return items.indices.sorted { rank($0) < rank($1) }
    }

    private static func canonical(_ item: TrashItem) -> Result<String, RefusalReason> {
        Result { () throws(RefusalReason) in try ProtectedPaths.canonicalPath(of: item.url) }
    }

    /// Only orders items: the `requiresGone` check itself is `lstat` on the path as given.
    private static func key(_ url: URL) -> String {
        ((try? ProtectedPaths.canonicalPath(of: url)) ?? url.standardizedFileURL.path).lowercased()
    }

    private mutating func process(_ item: TrashItem, canonical: Result<String, RefusalReason>) -> [TrashOutcome] {
        // An app's leftover goes only once nothing is at the app's path: not the app, a link, or a copy an updater
        // put back (section 2.1).
        if let required = item.requiresGone, !Self.isGone(required.path) {
            return [.failed(item.url, message: "Not removed, because \(required.lastPathComponent) is still there.")]
        }
        switch canonical {
        case .success(let path): return process(item, canonical: path)
        case .failure(let reason): return [.refused(item.url, reason)]
        }
    }

    private mutating func process(_ item: TrashItem, canonical path: String) -> [TrashOutcome] {
        let lowered = path.lowercased()
        if isKept(lowered) { return [.failed(item.url, message: "You chose to keep this, so it was not moved.")] }
        if let outcome = coveredOutcome(of: path, shownAs: item.url) { return [outcome] }
        if let reason = policy.refusal(canonical: path, cloudConfirmed: cloudConfirmed) { return [.refused(item.url, reason)] }
        // A folder on the way that became a link since the scan leads somewhere else, even where the object there
        // passes the identity check below, as a hard link of the scanned file does (T-0054).
        guard Self.samePlace(item.url.path, path) else { return [.refused(item.url, .identityChanged)] }
        guard let identity = FileIdentity(url: URL(fileURLWithPath: path)) else { return [.refused(item.url, .missing)] }
        if let expected = item.expectedIdentity, expected != identity { return [.refused(item.url, .identityChanged)] }

        let inside = keep.filter { $0.hasPrefix(lowered + "/") }
        if inside.isEmpty { return [sink(item.url, canonical: path, identity: identity, allocated: item.allocated)] }
        let pieces = removeKeeping(inside, in: path, shownAs: item.url)
        // Callers match outcomes to items by URL, so an item with no piece moved reports itself.
        let accounted = pieces.contains {
            switch $0 {
            case .trashed, .deleted: true
            case .refused, .failed: $0.url == item.url
            }
        }
        return accounted ? pieces : pieces + [.failed(item.url, message: "Nothing in it was moved: everything left in it is kept or refused.")]
    }

    /// Removes everything in `folder` except the kept paths, descending only into folders that hold one (F-0026).
    /// `keep` is lowercased: APFS matches names without case, so `OLD/src` must keep `old/src`.
    private mutating func removeKeeping(_ keep: Set<String>, in folder: String, shownAs shown: URL) -> [TrashOutcome] {
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
                outcomes += removeKeeping(keep, in: child, shownAs: childShown)
            } else if let reason = policy.refusal(canonical: child, cloudConfirmed: cloudConfirmed) {
                outcomes.append(.refused(childShown, reason))
            } else if let identity = FileIdentity(url: URL(fileURLWithPath: child)) {
                outcomes.append(sink(childShown, canonical: child, identity: identity, allocated: Self.fileSize(child)))
            } else {
                outcomes.append(.refused(childShown, .missing))
            }
        }
        return outcomes
    }

    private mutating func sink(_ shown: URL, canonical path: String, identity: FileIdentity, allocated: UInt64) -> TrashOutcome {
        if let journalError { return .failed(shown, message: journalError) }
        var info = stat()
        guard lstat(path, &info) == 0 else { return .refused(shown, .missing) }
        let isFolder = info.st_mode & S_IFMT == S_IFDIR
        // D4: in the cloud, a personal database, or evicted: to the Trash even when the batch deletes permanently.
        var erase = mode == .permanent && policy.trashOnlyReason(canonical: path) == nil && info.st_flags & UInt32(SF_DATALESS) == 0
        if isFolder {
            switch ProtectionPolicy.removalBlocker(inside: path, forErase: erase) {
            case .refused(let reason)?: return .refused(shown, reason)
            case .dataless?: erase = false
            case nil: break
            }
        }
        // The backend moves by path, and a path follows any link swapped in for one of its folders. So check the
        // way just before the move, and after it check that what left is what was checked (T-0053).
        let folder = (path as NSString).deletingLastPathComponent
        guard let before = Self.linkFreeIdentity(of: folder), FileIdentity(url: URL(fileURLWithPath: path)) == identity else {
            return .refused(shown, .identityChanged)
        }
        if erase && !isFolder { return deleteInPlace(shown, canonical: path, identity: identity, allocated: allocated) }
        let destination: URL
        do {
            destination = try backend.moveToTrash(URL(fileURLWithPath: path))
        } catch {
            return .failed(shown, message: Self.message(for: error, moving: path))
        }
        guard FileIdentity(url: destination) == identity, Self.linkFreeIdentity(of: folder) == before else {
            return putBack(destination, movedFrom: path, shownAs: shown, checked: identity)
        }
        let key = path.lowercased()
        guard erase else {
            gone[key] = .trashed(destination)
            record(original: path, trashedTo: destination, identity: identity, allocated: allocated)
            return .trashed(original: shown, trashedTo: destination)
        }
        // The erase works on the object just moved, found again by its identity through the Trash folder.
        switch engine.erase(trashed: destination, identity: identity) {
        case .removed:
            gone[key] = .erased(destination)
            record(original: path, trashedTo: nil, identity: identity, allocated: allocated)
            return .deleted(original: shown)
        case .changed:
            gone[key] = .trashed(destination)
            record(original: path, trashedTo: destination, identity: identity, allocated: allocated)
            return .failed(shown, message: "Moved to the Trash, but not deleted: it changed there. Empty the Trash to finish.")
        case .failed(let failures):
            // Bytes were removed, so History must show it; a half-deleted folder is not worth an Undo.
            gone[key] = .erased(destination)
            record(original: path, trashedTo: nil, identity: identity, allocated: allocated)
            return .failed(shown, message: Self.partlyDeleted(failures, trashName: destination.lastPathComponent))
        }
    }

    /// A file, a link or any other non-folder in permanent mode: one `unlinkat` at its place (section 2.1).
    private mutating func deleteInPlace(_ shown: URL, canonical path: String, identity: FileIdentity, allocated: UInt64) -> TrashOutcome {
        switch engine.deleteFile(canonical: path, identity: identity) {
        case .removed:
            gone[path.lowercased()] = .deleted
            record(original: path, trashedTo: nil, identity: identity, allocated: allocated)
            return .deleted(original: shown)
        case .changed:
            return .refused(shown, .identityChanged)
        case .failed(let failures):
            return .failed(shown, message: "It could not be deleted: \(failures.first?.reason ?? "unknown error").")
        }
    }

    static func partlyDeleted(_ failures: [RemovalEngine.Failure], trashName: String) -> String {
        let count = failures.count == 1 ? "1 item" : "\(failures.count) items"
        let first = failures.first.map { ($0.path.isEmpty ? trashName : $0.path) + ": " + $0.reason } ?? ""
        return "Partly deleted. \(count) inside could not be removed; the rest is in the Trash as \"\(trashName)\". "
            + "Empty the Trash to finish. First: \(first)"
    }

    /// App Management (macOS 13+) answers EPERM when an app bundle it guards is moved. Unverified which error
    /// `FileManager.trashItem` wraps it in, so the POSIX code is looked for down the underlying errors (T-0078 checks).
    private static func message(for error: any Error, moving path: String) -> String {
        var current: NSError? = error as NSError
        while let error = current, error.domain != NSPOSIXErrorDomain {
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if current?.code == Int(EPERM) && (path as NSString).pathExtension.lowercased() == "app" {
            return "macOS blocked this. Allow Macontrol in System Settings > Privacy & Security > App Management."
        }
        return error.localizedDescription
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

    private mutating func record(original path: String, trashedTo destination: URL?, identity: FileIdentity, allocated: UInt64) {
        let entry = JournalEntry(
            batch: id, date: Date(), originalPath: path, trashedPath: destination?.path,
            identity: identity, allocated: allocated, restored: false, restorePoint: restorePoint
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

    /// The outcome of `path` if it, or a folder holding it, went earlier in this batch.
    private func coveredOutcome(of path: String, shownAs shown: URL) -> TrashOutcome? {
        var ancestor = path
        var relative: [String] = []
        while true {
            if let went = gone[ancestor.lowercased()] {
                // Keys ignore case, so on a case-sensitive volume `Cache` matches `cache`: believe the match only when
                // the item really left its path.
                guard !Self.exists(path) else { return nil }
                switch went {
                case .deleted:
                    return .deleted(original: shown)
                case .trashed(let folder), .erased(let folder):
                    let destination = relative.reduce(folder) { $0.appendingPathComponent($1) }
                    // Still in the Trash (moved there, or left by a partial erase) at that place.
                    if Self.exists(destination.path) { return .trashed(original: shown, trashedTo: destination) }
                    if case .erased = went { return .deleted(original: shown) }
                    return nil
                }
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

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Nothing at all at `path`. Any other answer (a permission error included) counts as still there.
    private static func isGone(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
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
        case .trashed(let url, _), .deleted(let url), .refused(let url, _), .failed(let url, _): url
        }
    }
}
