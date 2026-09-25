import Darwin
import Foundation
import MacontrolCore

/// Pass 2 of `TrashService.remove` (DESIGN-debloat section 3.6): the items pass 1 refused with `.needsAdministrator`
/// go to the helper in one request, in order, behind one administrator dialog. The app side of section 3.3.
public enum PrivilegedRouting {
    /// One outcome per item, in the order of `items`; each replaces that item's refusal. `notes` holds what the user
    /// should know about an item that went (`TrashReport.notes`).
    public typealias Answer = (outcomes: [TrashOutcome], notes: [URL: String])

    /// `batch`, `journalURL` and `restorePoint` are the calling batch's, for the journal lines written as results
    /// arrive (section 3.3 step 5); `home` is the requesting user's.
    public static func run(
        _ items: [TrashItem], mode: DeletionMode, launcher: PrivilegedLauncher,
        batch: UUID, journalURL: URL, home: URL, restorePoint: String?
    ) async -> Answer {
        await run(items, mode: mode, launcher: launcher, batch: batch, journalURL: journalURL, home: home,
                  restorePoint: restorePoint, resultOwner: 0, systemRoot: "/")
    }

    /// `resultOwner` is root, and `systemRoot` `/`, except in tests that run the debug helper as themselves.
    static func run(
        _ items: [TrashItem], mode: DeletionMode, launcher: PrivilegedLauncher, batch: UUID, journalURL: URL, home: URL,
        restorePoint: String?, resultOwner: uid_t, systemRoot: String, pidTimeout: Duration = .seconds(5)
    ) async -> Answer {
        let homePath = (try? ProtectedPaths.canonicalPath(of: home)) ?? home.path
        var outcomes = items.map { refusal(of: $0, home: homePath, systemRoot: systemRoot) }
        let sent = items.indices.filter { outcomes[$0] == nil }
        let request = PrivilegedRequest(op: mode, items: sent.map { index in
            let item = items[index]
            return PrivilegedRequest.Item(
                path: item.url.path, identity: item.expectedIdentity!, allocated: item.allocated,
                bundleIdentifier: item.bundleIdentifier, requiresGone: item.requiresGone?.path
            )
        })
        var notes: [URL: String] = [:]
        func fail(_ message: String) -> Answer {
            (items.indices.map { outcomes[$0] ?? .failed(items[$0].url, message: message) }, notes)
        }
        guard !sent.isEmpty else { return fail("") }

        let journal: FileHandle
        do {
            journal = try TrashJournal(url: journalURL).openForAppending()
        } catch {
            return fail("The undo journal could not be opened: \(error.localizedDescription)")
        }
        let priv = journalURL.deletingLastPathComponent().appendingPathComponent("priv")
        guard let data = try? request.encoded(), let folder = RequestFolder(in: priv, batch: batch), folder.write(data) else {
            return fail("The request for the administrator helper could not be written.")
        }
        defer { folder.remove() }
        let sha = PrivilegedRequest.sha256(data)
        let requestURL = folder.request
        let text = prompt(count: sent.count, mode: mode)
        do {
            try await MainActor.run { try launcher.start(launcher.helperURL, requestURL, sha, text) }
        } catch {
            return fail(message(for: error as? PrivilegedError ?? .launchFailed(error.localizedDescription)))
        }

        // Opened once and checked once: a file root created, with one link. The path is never read again.
        guard var results = ResultReader(in: folder.descriptor, owner: resultOwner) else {
            return fail("The administrator helper's results could not be read.")
        }
        defer { results.close() }
        let started = ContinuousClock.now
        var pid: pid_t?
        var finished = false
        while !finished {
            let lines = results.lines()
            for line in lines {
                pid = pid ?? line.pid
                finished = finished || line.done == true
                guard let index = line.index, sent.indices.contains(index), outcomes[sent[index]] == nil,
                      let outcome = line.outcome(for: items[sent[index]].url) else { continue }
                outcomes[sent[index]] = outcome
                notes[items[sent[index]].url] = line.note
                if let entry = journalEntry(line, request.items[index], batch: batch, restorePoint: restorePoint) {
                    // ponytail: root cannot be stopped mid-batch like v1's journalError; a lost line only leaves History short.
                    try? TrashJournal.append(entry, to: journal)
                }
            }
            if finished { break }
            let alive = pid.map { kill($0, 0) == 0 || errno == EPERM } ?? (ContinuousClock.now - started < pidTimeout)
            // A last read catches the lines it wrote just before it ended.
            if !alive && lines.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The helper works in order, so the first item it did not answer is the one it was on: some or all of it may
        // have gone. The rest were never touched.
        if !finished, let current = sent.first(where: { outcomes[$0] == nil }) {
            outcomes[current] = .failed(items[current].url, message: Self.stoppedOnIt)
        }
        return fail(message(for: .helperStopped))
    }

    /// Why an item never reaches the helper: checked in the app too, so an item root would refuse never costs a dialog.
    static func refusal(of item: TrashItem, home: String, systemRoot: String) -> TrashOutcome? {
        guard item.keep.isEmpty else {
            return .failed(item.url, message: "Parts of it are unchecked, so it can't be removed as administrator.")
        }
        guard item.expectedIdentity != nil else { return .refused(item.url, .identityChanged) }
        let canonical: String
        do throws(RefusalReason) {
            canonical = try ProtectedPaths.canonicalPath(of: item.url)
        } catch {
            return .refused(item.url, error)
        }
        // The helper acts only on the canonical spelling: any other one may lead through a link.
        guard canonical == item.url.path else { return .refused(item.url, .identityChanged) }
        return PrivilegedScope.refusal(canonical: canonical, home: home, bundleIdentifier: item.bundleIdentifier, systemRoot: systemRoot)
            .map { .refused(item.url, $0) }
    }

    /// The dialog's text: data, never code (section 3.3 step 3).
    static func prompt(count: Int, mode: DeletionMode) -> String {
        let items = count == 1 ? "1 item" : "\(count) items"
        return switch mode {
        case .trash: "macontrol needs your administrator password to move \(items) owned by the system to the Trash."
        case .permanent: "macontrol needs your administrator password to delete \(items) owned by the system permanently."
        }
    }

    static let stoppedOnIt = "The administrator helper stopped while it worked on this, so some or all of it may "
        + "already be gone or in the Trash."

    static func message(for error: PrivilegedError) -> String {
        switch error {
        case .cancelled: "Not removed: the administrator password was not given."
        case .helperRejected(let status): "The administrator helper refused the request (exit \(status)), so nothing was removed."
        case .helperStopped: "The administrator helper stopped before it got to this."
        case .launchFailed(let reason): "The administrator helper could not start (\(reason)), so nothing was removed."
        }
    }

    /// The History line for a result: trashed, deleted, or failed but in the Trash or partly deleted. Moved by the
    /// helper, so it has no in-app Undo (D12).
    static func journalEntry(
        _ line: PrivilegedResultLine, _ item: PrivilegedRequest.Item, batch: UUID, restorePoint: String?
    ) -> JournalEntry? {
        let trashedPath: String?
        switch (line.status, line.to, line.partial) {
        case ("trashed", let to?, _), ("failed", let to?, _): trashedPath = to
        case ("deleted", _, _), ("failed", nil, true?): trashedPath = nil
        default: return nil
        }
        return JournalEntry(
            batch: batch, date: Date(), originalPath: item.path, trashedPath: trashedPath, identity: item.identity,
            allocated: item.allocated, restored: false, restorePoint: restorePoint, asAdministrator: true
        )
    }

    // MARK: Crash recovery (section 3.8)

    /// Journals what a helper finished while the app was gone, then removes its request folder. Only a result file that
    /// root created (regular, `resultOwner`, one link) is read, and only once its helper is gone; any other is removed
    /// unread. A line already in the journal (same batch and path) is not added again.
    static func recover(journalURL: URL, resultOwner: uid_t = 0) {
        let priv = journalURL.deletingLastPathComponent().appendingPathComponent("priv")
        let journal = TrashJournal(url: journalURL)
        var journaled: Set<String>?
        for name in (try? FileManager.default.contentsOfDirectory(atPath: priv.path)) ?? [] {
            guard let batch = UUID(uuidString: String(name.prefix(36))), let folder = RequestFolder(existing: name, in: priv) else { continue }
            defer { folder.remove() }
            guard var results = ResultReader(in: folder.descriptor, owner: resultOwner) else { continue }
            defer { results.close() }
            let lines = results.lines()
            if !lines.contains(where: { $0.done == true }), let pid = lines.first(where: { $0.pid != nil })?.pid,
               kill(pid, 0) == 0 || errno == EPERM {
                folder.keep()
                continue
            }
            guard let request = folder.readRequest() else { continue }
            var known = journaled ?? Set(journal.entries().map { "\($0.batch)\n\($0.originalPath)" })
            let entries = lines.compactMap { line -> JournalEntry? in
                guard let index = line.index, request.items.indices.contains(index) else { return nil }
                return journalEntry(line, request.items[index], batch: batch, restorePoint: nil)
            }.filter { known.insert("\($0.batch)\n\($0.originalPath)").inserted }
            journaled = known
            guard !entries.isEmpty, let handle = try? journal.openForAppending() else { continue }
            for entry in entries { try? TrashJournal.append(entry, to: handle) }
        }
    }
}

/// `priv/<batch>.XXXXXX`: a 0700 folder of the user's, inside the journal's folder, which the policy protects.
/// Everything in it is reached through its descriptor.
final class RequestFolder {
    let request: URL
    let descriptor: Int32
    private let parent: Int32
    private let name: String
    private var keeps = false

    /// A new folder, made with `mkdtemp`.
    convenience init?(in priv: URL, batch: UUID) {
        mkdir(priv.path, 0o700)
        var template = Array("\(priv.path)/\(batch.uuidString).XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { return nil }
        let made = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        self.init(existing: (made as NSString).lastPathComponent, in: priv)
    }

    init?(existing name: String, in priv: URL) {
        parent = open(priv.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { return nil }
        descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            Darwin.close(parent)
            return nil
        }
        self.name = name
        request = priv.appendingPathComponent(name).appendingPathComponent("request.json")
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(parent)
    }

    /// `request.json`, 0600, created here and nowhere else (`O_EXCL`, no link followed).
    func write(_ data: Data) -> Bool {
        let fd = openat(descriptor, "request.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == data.count
    }

    func readRequest() -> PrivilegedRequest? {
        let fd = openat(descriptor, "request.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        return FileHandle(fileDescriptor: fd).readData(ofLength: PrivilegedRequest.maximumSize + 1).nonEmpty.flatMap(PrivilegedRequest.decode)
    }

    /// Leaves the folder for a later launch (its helper is still working).
    func keep() { keeps = true }

    /// The two files and the folder, by name from their descriptors. Anything else placed in it keeps the folder.
    func remove() {
        guard !keeps else { return }
        unlinkat(descriptor, "request.json", 0)
        unlinkat(descriptor, "result.jsonl", 0)
        unlinkat(parent, name, AT_REMOVEDIR)
    }
}

/// `result.jsonl`, opened once: a regular file owned by `owner` (root), with one link, so a file a same-user process
/// planted or hard-linked is never read. Read through that descriptor only, as the helper appends.
struct ResultReader {
    private let descriptor: Int32
    private var pending = Data()

    init?(in folder: Int32, owner: uid_t) {
        let fd = openat(folder, "result.jsonl", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner, info.st_nlink == 1 else {
            Darwin.close(fd)
            return nil
        }
        descriptor = fd
    }

    /// The complete lines appended since the last call; a line that does not decode is skipped.
    mutating func lines() -> [PrivilegedResultLine] {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            pending.append(contentsOf: buffer.prefix(count))
        }
        guard let last = pending.lastIndex(of: 0x0A) else { return [] }
        let complete = pending[..<last]
        pending = Data(pending[pending.index(after: last)...])
        return complete.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(PrivilegedResultLine.self, from: Data($0)) }
    }

    func close() { Darwin.close(descriptor) }
}

private extension Data {
    var nonEmpty: Data? { isEmpty ? nil : self }
}
