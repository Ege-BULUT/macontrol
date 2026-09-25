import Darwin
import Foundation
import MacontrolCore

/// Why the helper's foreground check refused a request: its exit status (`sysexits.h`), which the app sees as the
/// AppleScript error number (DESIGN-debloat section 3.4).
public enum PrivilegedExit: Int32, Error, Sendable {
    /// Malformed, oversized or of an unknown version.
    case malformed = 65
    /// A wrong owner or mode, a link on the way, or a hash that does not match the call the user authorized.
    case notPermitted = 77
    /// The result file could not be created (a name already there, a link), or the detach failed.
    case systemError = 71
}

/// The administrator helper's work (DESIGN-debloat section 3.5). The foreground check reads the request once; the
/// detached child then takes each item through the root allowlist, the v1 policy built for the requesting user, its
/// identity and checks, and moves it into that user's Trash. `macontrol-priv`'s main.swift only parses argv and forks
/// between the two, so the child works from bytes checked before the fork and never reads the request file again.
public struct PrivilegedExecutor: Sendable {
    /// Runs `/bin/launchctl` with these arguments; its exit status and standard output.
    public typealias Launchctl = @Sendable (_ arguments: [String]) -> (status: Int32, output: String)

    /// A request that passed the foreground check, and the result file it created.
    public struct Checked: Sendable {
        public let request: PrivilegedRequest
        /// Owner of the request folder: the user who asked.
        let user: uid_t
        /// `result.jsonl`, created by this check (`O_EXCL`), open for appending.
        let result: Int32
    }

    /// `/` in the helper. Tests point it at a temporary folder standing in for /Applications, /Library and the receipts.
    let systemRoot: String
    /// The effective user the check requires: root in the helper, the current user in tests.
    let euid: uid_t
    /// Tests' stand-in for the requesting user's home. The helper asks the user database for the folder owner's.
    let homeOverride: String?
    let launchctl: Launchctl
    /// Tests only: runs before item N is looked at (to rewrite the request or stop the helper there).
    let beforeItem: (@Sendable (Int) -> Void)?
    /// Tests only: runs between an item's last check and its rename, with its path.
    let beforeRename: (@Sendable (String) -> Void)?

    public init(launchctl: @escaping Launchctl) {
        systemRoot = "/"
        euid = 0
        homeOverride = nil
        self.launchctl = launchctl
        beforeItem = nil
        beforeRename = nil
    }

    #if DEBUG
    /// Tests only, and only in debug builds: the release helper has no test flags.
    public init(
        testRoot: String, home: String, launchctl: @escaping Launchctl,
        beforeItem: (@Sendable (Int) -> Void)? = nil, beforeRename: (@Sendable (String) -> Void)? = nil
    ) {
        systemRoot = testRoot
        euid = geteuid()
        homeOverride = home
        self.launchctl = launchctl
        self.beforeItem = beforeItem
        self.beforeRename = beforeRename
    }
    #endif

    // MARK: Foreground check

    /// Everything the helper reads from the user's side, read once: the folder (0700, owned by a user other than root),
    /// `request.json` in it (a regular 0600 file of that user, at most 1 MiB) and its SHA-256, which must equal the one
    /// the user authorized. Then `result.jsonl` is created with `O_EXCL`, so a name placed there beforehand fails.
    /// Starts no thread: the process forks after this.
    public func check(requestPath: String, sha256: String) -> Result<Checked, PrivilegedExit> {
        guard geteuid() == euid else { return .failure(.notPermitted) }
        guard requestPath.hasPrefix("/"), (requestPath as NSString).lastPathComponent == "request.json",
              sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil else { return .failure(.malformed) }
        let folder = open((requestPath as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard folder >= 0 else { return .failure(.notPermitted) }
        defer { close(folder) }
        var info = stat()
        guard fstat(folder, &info) == 0, info.st_uid != 0, info.st_mode & 0o7777 == 0o700 else { return .failure(.notPermitted) }
        let user = info.st_uid

        let file = openat(folder, "request.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return .failure(.notPermitted) }
        defer { close(file) }
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == user,
              info.st_mode & 0o7777 == 0o600 else { return .failure(.notPermitted) }
        guard info.st_size <= PrivilegedRequest.maximumSize, let data = Self.read(file) else { return .failure(.malformed) }
        guard PrivilegedRequest.sha256(data) == sha256 else { return .failure(.notPermitted) }
        guard let request = PrivilegedRequest.decode(data) else { return .failure(.malformed) }

        let result = openat(folder, "result.jsonl", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_APPEND | O_CLOEXEC, 0o644)
        guard result >= 0 else { return .failure(.systemError) }
        return .success(Checked(request: request, user: user, result: result))
    }

    /// The whole file through its fd, at most one byte past the limit (which then fails to decode).
    private static func read(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= PrivilegedRequest.maximumSize {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    // MARK: The detached child

    /// Writes `{"pid":N}`, one result line per item in order, then `{"done":true}`, each fsync'd.
    public func run(_ checked: Checked) {
        write(PrivilegedResultLine(pid: getpid()), to: checked.result)
        let items = checked.request.items
        // The requesting user's home, never this process's: as root that would be /var/root (section 3.5, sec 6).
        // Looked up after the fork, because the user database may start threads.
        guard let home = homeOverride ?? Self.home(of: checked.user),
              let trash = Self.openTrash(home + "/.Trash", owner: checked.user) else {
            let failure = HelperOutcome.failed("Your Trash folder could not be opened, so nothing was moved.")
            for index in items.indices { write(.outcome(index, failure), to: checked.result) }
            write(PrivilegedResultLine(done: true), to: checked.result)
            return
        }
        defer { close(trash) }
        let policy = Self.policy(home: home)
        for (index, item) in items.enumerated() {
            beforeItem?(index)
            var note: String?
            var line = PrivilegedResultLine.outcome(index, process(item, op: checked.request.op, home: home, policy: policy, trash: trash, note: &note))
            line.note = note
            write(line, to: checked.result)
        }
        write(PrivilegedResultLine(done: true), to: checked.result)
    }

    /// Section 3.5 "per item", in order; nothing changes before the last check. `note` is set when the item went but
    /// its LaunchDaemon may still run.
    func process(
        _ item: PrivilegedRequest.Item, op: DeletionMode, home: String, policy: ProtectionPolicy, trash: Int32, note: inout String?
    ) -> HelperOutcome {
        if let refusal = refusal(of: item, home: home, policy: policy) { return Self.asRoot(refusal) }
        let path = item.path
        var info = stat()
        let isFolder = lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        // D4: cloud items, the personal databases and evicted iCloud content go to the Trash even in permanent mode.
        var erase = op == .permanent && policy.trashOnlyReason(canonical: path) == nil && info.st_flags & UInt32(SF_DATALESS) == 0
        // Root never clears a flag: a locked or system-protected entry inside keeps the whole item.
        switch ProtectionPolicy.removalBlocker(inside: path, forErase: erase) {
        case .refused(let reason)?: return Self.asRoot(.refused(reason))
        case .dataless?: erase = false
        case nil: break
        }
        var skipped: String?
        if isLaunchDaemon(path), let failure = stopDaemon(path, note: &skipped) { return failure }
        let outcome = remove(path, identity: item.identity, erase: erase, isFolder: isFolder, home: home, trash: trash)
        // Only a plist that left its place leaves a job running without it.
        switch outcome {
        case .trashed, .deleted: note = skipped
        case .refused, .failed: break
        }
        return outcome
    }

    /// "Needs an administrator" is false right after the password: as root only privacy protection (TCC) or SIP answers
    /// EACCES or EPERM, so the item was out of the helper's reach too (T-0075 review 2).
    static func asRoot(_ outcome: HelperOutcome) -> HelperOutcome {
        outcome == .refused(.needsAdministrator) ? .failed(rootKeptOut) : outcome
    }

    static let rootKeptOut = "Not removed: macOS kept even the administrator out of part of it (privacy protection or System Integrity Protection)."

    /// The sink: the Trash, or a permanent delete (section 3.5 step 5).
    private func remove(_ path: String, identity: FileIdentity, erase: Bool, isFolder: Bool, home: String, trash: Int32) -> HelperOutcome {
        // D3, the code the app uses: a file is one unlinkat in place; a folder goes to the Trash first, then the
        // trashed copy is erased, so a stop halfway leaves the rest in the Trash, never half an app in place.
        if erase && !isFolder {
            switch RemovalEngine().deleteFile(canonical: path, identity: identity) {
            case .removed: return .deleted
            case .changed: return .refused(.identityChanged)
            case .failed(let failures), .partly(let failures):
                return .failed("It could not be deleted: \(failures.first?.reason ?? "unknown error").")
            }
        }
        let moved = moveToTrash(path, identity: identity, home: home, trash: trash)
        guard erase, case .trashed(let to) = moved else { return moved }
        switch RemovalEngine().erase(trashed: URL(fileURLWithPath: to), identity: identity) {
        case .removed: return .deleted
        case .changed: return .failed("Moved to the Trash, but not deleted: it changed there. Empty the Trash to finish.", to: to)
        case .failed(let failures):
            // Nothing was removed: it is whole in the Trash, where History has no Undo for what root moved (D12).
            return .failed(TrashBatch.notDeleted(failures, trashName: (to as NSString).lastPathComponent, asAdministrator: true), to: to)
        case .partly(let failures):
            return .failed(TrashBatch.partlyDeleted(failures, trashName: (to as NSString).lastPathComponent), partial: true)
        }
    }

    /// Every check before a change, none of which touches the disk: the canonical spelling, the root allowlist, the
    /// requesting user's policy, identity, and `requiresGone`. What is inside a folder is `process`'s removal blocker.
    func refusal(of item: PrivilegedRequest.Item, home: String, policy: ProtectionPolicy) -> HelperOutcome? {
        let path: String
        do throws(RefusalReason) {
            path = try ProtectedPaths.canonicalPath(of: URL(fileURLWithPath: item.path))
        } catch {
            return .refused(error)
        }
        // The app sends canonical paths; any other spelling may lead through a link to somewhere else.
        guard path == item.path else { return .refused(.identityChanged) }
        if let reason = PrivilegedScope.refusal(canonical: path, home: home, bundleIdentifier: item.bundleIdentifier, systemRoot: systemRoot)
            ?? policy.refusal(canonical: path, cloudConfirmed: false) {
            return .refused(reason)
        }
        guard FileIdentity(url: URL(fileURLWithPath: path)) == item.identity else { return .refused(.identityChanged) }
        if let gone = item.requiresGone {
            var info = stat()
            guard lstat(gone, &info) != 0 && errno == ENOENT else {
                return .failed("Not removed, because \((gone as NSString).lastPathComponent) is still there.")
            }
        }
        return nil
    }

    /// The requesting user's policy: their home and their journal, spelled out, never this process's (sec 6).
    static func policy(home: String) -> ProtectionPolicy {
        let home = URL(fileURLWithPath: home)
        return ProtectionPolicy(home: home, journal: home.appendingPathComponent("Library/Application Support/Macontrol/trash-journal.jsonl"))
    }

    // MARK: LaunchDaemons

    private func isLaunchDaemon(_ path: String) -> Bool {
        let root = systemRoot == "/" ? "" : systemRoot
        return (path as NSString).deletingLastPathComponent == root + "/Library/LaunchDaemons" && path.hasSuffix(".plist")
    }

    /// Boots out `system/<Label>` only when launchd says it loaded that job from this very file. A stale plist can carry
    /// the label of another daemon, and `launchctl print` "is NOT API", so anything else only skips the bootout: the file
    /// still goes, and the job stops at the next restart (section 3.5 step 4, Risk 7), which `note` then says whenever
    /// launchd may be running it: unless launchctl said it has no such job. Nil when the item may go on.
    private func stopDaemon(_ path: String, note: inout String?) -> HelperOutcome? {
        // launchd loads no job from a plist without a Label.
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return nil }
        guard label.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil else {
            note = Self.untilRestart
            return nil
        }
        let printed = launchctl(["print", "system/\(label)"])
        let loadedFromHere = printed.status == 0 && printed.output.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "path = \(path)"
        }
        guard loadedFromHere else {
            // 113: launchd has no such job. Anything else, launchctl failing to run included, may leave it running.
            if printed.status != 113 { note = Self.untilRestart }
            return nil
        }
        let status = launchctl(["bootout", "system/\(label)"]).status
        // 3: not loaded (ESRCH), nothing left to stop.
        guard status == 0 || status == 3 else {
            return .failed("Its background service \(label) could not be stopped (launchctl exit \(status)), so it was not removed.")
        }
        return nil
    }

    static let untilRestart = "Its background service may keep running until the next restart."

    // MARK: The Trash sink

    /// Renames the item, by name from its opened parent, into the user's Trash (`RENAME_EXCL`, Finder's "Name 14.03.27"
    /// on a collision), then checks that what arrived is what was checked, and puts back anything else (T-0053). Never
    /// `FileManager.trashItem`: as root that is root's Trash. The item keeps its owner.
    private func moveToTrash(_ path: String, identity: FileIdentity, home: String, trash: Int32) -> HelperOutcome {
        let name = (path as NSString).lastPathComponent
        let parent = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { return .refused(.identityChanged) }
        defer { close(parent) }
        guard Self.identity(of: name, in: parent) == identity else { return .refused(.identityChanged) }
        beforeRename?(path)
        var trashed = name
        var attempt = 0
        while renameatx_np(parent, name, trash, trashed, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            attempt += 1
            if code == EXDEV { return .failed("Only items on the startup disk can be moved to the Trash as administrator.") }
            // App Management answers EPERM for an app bundle, root or not, as it does in-process (DESIGN 2.4).
            if code == EPERM && (name as NSString).pathExtension.lowercased() == "app" { return .failed(TrashBatch.appManagementBlocked) }
            guard code == EEXIST, attempt < 20 else { return .failed(String(cString: strerror(code))) }
            trashed = Self.finderName(name, attempt: attempt)
        }
        let to = home + "/.Trash/" + trashed
        guard Self.identity(of: trashed, in: trash) == identity else {
            if renameatx_np(trash, trashed, parent, name, UInt32(RENAME_EXCL)) == 0 { return .refused(.identityChanged) }
            return .failed("It changed as it moved, and what reached the Trash instead could not be put back.", to: to)
        }
        return .trashed(to: to)
    }

    /// Finder's pattern for a name the Trash already has: "Name 14.03.27.app", then "Name 14.03.27 2.app".
    static func finderName(_ name: String, attempt: Int, now: Date = Date()) -> String {
        var seconds = time_t(now.timeIntervalSince1970)
        var local = tm()
        localtime_r(&seconds, &local)
        let time = String(format: "%02d.%02d.%02d", local.tm_hour, local.tm_min, local.tm_sec)
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        return stem + " " + time + (attempt > 1 ? " \(attempt)" : "") + (suffix.isEmpty ? "" : "." + suffix)
    }

    // MARK: Helpers

    private static func identity(of name: String, in folder: Int32) -> FileIdentity? {
        var info = stat()
        return fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil
    }

    /// The home folder of `user`, canonical and owned by them.
    private static func home(of user: uid_t) -> String? {
        guard let entry = getpwuid(user), let directory = entry.pointee.pw_dir,
              let home = try? ProtectedPaths.canonicalPath(of: URL(fileURLWithPath: String(cString: directory))) else { return nil }
        var info = stat()
        return lstat(home, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == user ? home : nil
    }

    /// `<home>/.Trash`, opened with no link anywhere on the way and owned by the user.
    private static func openTrash(_ path: String, owner: uid_t) -> Int32? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner else {
            close(fd)
            return nil
        }
        return fd
    }

    private func write(_ line: PrivilegedResultLine, to fd: Int32) {
        let data = line.encoded()
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
    }
}
