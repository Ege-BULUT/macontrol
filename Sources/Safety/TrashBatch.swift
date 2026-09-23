import Darwin
import Foundation
import MacontrolCore

/// One `moveToTrash` call. Per item, in order: skip it if a selected ancestor already went (F-0050),
/// apply the protected-path policy, re-check its identity, expand `keep`, trash, journal.
struct TrashBatch {
    let id: UUID
    let policy: ProtectionPolicy
    let backend: TrashBackend
    let journal: FileHandle
    let cloudConfirmed: Bool
    /// Canonical path of every item trashed so far, and where it went.
    private var trashed: [String: URL] = [:]
    /// Set when a journal line could not be written: nothing more is trashed without an undo record.
    private var journalError: String?

    init(id: UUID, policy: ProtectionPolicy, backend: TrashBackend, journal: FileHandle, cloudConfirmed: Bool) {
        self.id = id
        self.policy = policy
        self.backend = backend
        self.journal = journal
        self.cloudConfirmed = cloudConfirmed
    }

    mutating func process(_ items: [TrashItem]) -> [TrashOutcome] {
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
        if let destination = trashedAncestor(of: path) {
            return [.trashed(original: item.url, trashedTo: destination)]
        }
        if let reason = policy.refusal(canonical: path, cloudConfirmed: cloudConfirmed) { return [.refused(item.url, reason)] }
        guard let identity = FileIdentity(url: URL(fileURLWithPath: path)) else { return [.refused(item.url, .missing)] }
        if let expected = item.expectedIdentity, expected != identity { return [.refused(item.url, .identityChanged)] }

        let keep = Set(item.keep.compactMap { try? ProtectedPaths.canonicalPath(of: $0) }.filter { $0.hasPrefix(path + "/") })
        if keep.isEmpty { return [trash(item.url, canonical: path, identity: identity, allocated: item.allocated)] }
        return trashKeeping(keep, in: path, shownAs: item.url)
    }

    /// Trashes everything in `folder` except the kept paths, descending only into folders that hold one (F-0026).
    private mutating func trashKeeping(_ keep: Set<String>, in folder: String, shownAs shown: URL) -> [TrashOutcome] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            return [.failed(shown, message: "The folder could not be read.")]
        }
        var outcomes: [TrashOutcome] = []
        for name in names.sorted() {
            let child = folder + "/" + name
            let childShown = shown.appendingPathComponent(name)
            if keep.contains(child) { continue }
            if keep.contains(where: { $0.hasPrefix(child + "/") }) && Self.isRealFolder(child) {
                outcomes += trashKeeping(keep, in: child, shownAs: childShown)
            } else if let reason = policy.refusal(canonical: child, cloudConfirmed: cloudConfirmed) {
                outcomes.append(.refused(childShown, reason))
            } else if let identity = FileIdentity(url: URL(fileURLWithPath: child)) {
                outcomes.append(trash(childShown, canonical: child, identity: identity, allocated: Self.fileSize(child)))
            }
        }
        return outcomes
    }

    private mutating func trash(_ shown: URL, canonical path: String, identity: FileIdentity, allocated: UInt64) -> TrashOutcome {
        if let journalError { return .failed(shown, message: journalError) }
        let destination: URL
        do {
            destination = try backend.moveToTrash(URL(fileURLWithPath: path))
        } catch {
            return .failed(shown, message: error.localizedDescription)
        }
        trashed[path] = destination
        let entry = JournalEntry(
            batch: id, date: Date(), originalPath: path, trashedPath: destination.path,
            identity: identity, allocated: allocated, restored: false
        )
        do {
            try TrashJournal.append(entry, to: journal)
        } catch {
            journalError = "Stopped: the undo journal could not be written (\(error.localizedDescription))."
        }
        return .trashed(original: shown, trashedTo: destination)
    }

    private func trashedAncestor(of path: String) -> URL? {
        var ancestor = path
        var relative: [String] = []
        while ancestor != "/" {
            relative.insert((ancestor as NSString).lastPathComponent, at: 0)
            ancestor = (ancestor as NSString).deletingLastPathComponent
            if let destination = trashed[ancestor] {
                return relative.reduce(destination) { $0.appendingPathComponent($1) }
            }
        }
        return nil
    }

    private func depth(_ path: Result<String, RefusalReason>) -> Int {
        (try? path.get())?.split(separator: "/").count ?? 0
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
