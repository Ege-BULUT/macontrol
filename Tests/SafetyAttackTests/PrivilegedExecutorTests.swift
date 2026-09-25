import Darwin
import Foundation
import MacontrolCore
@testable import Safety
import TestSupport
import Testing

/// A temporary system root and home for the helper's executor, run in-process as the current user (DESIGN-debloat
/// section 3.9). `root/` stands in for /Applications, /Library and the receipts; `home/.Trash` is the user's Trash.
/// launchctl is a recorder. Nothing here leaves the temporary folder.
final class RootFixture: @unchecked Sendable {
    let tmp: TemporaryDirectory
    var root: URL { tmp.url.appendingPathComponent("root") }
    var home: URL { tmp.url.appendingPathComponent("home") }
    var trash: URL { home.appendingPathComponent(".Trash") }
    private let lock = NSLock()
    private var calls: [[String]] = []
    /// What `launchctl print` answers, and the bootout status.
    var printed: (status: Int32, output: String) = (113, "")
    var bootoutStatus: Int32 = 0

    init() throws {
        tmp = try TemporaryDirectory()
        for folder in [
            "root/Applications", "root/Library/Application Support", "root/Library/Caches", "root/Library/LaunchDaemons",
            "root/Library/Preferences", "root/private/var/db/receipts", "root/private/etc", "home/.Trash", "home/Documents",
            "home/Library/Caches", "home/Library/Application Support/Macontrol/priv",
        ] {
            try tmp.directory(folder)
        }
    }

    var launchctlCalls: [[String]] { lock.withLock { calls } }

    var launchctl: PrivilegedExecutor.Launchctl {
        { [self] arguments in
            lock.withLock {
                calls.append(arguments)
                return arguments.first == "print" ? printed : (bootoutStatus, "")
            }
        }
    }

    func url(_ relative: String) -> URL { tmp.url.appendingPathComponent(relative) }

    @discardableResult
    func file(_ relative: String) throws -> URL { try tmp.file(relative, size: 4096) }

    /// A request item for the object at `relative` now.
    func item(_ relative: String, bundleIdentifier: String? = nil, requiresGone: String? = nil) throws -> PrivilegedRequest.Item {
        let url = url(relative)
        return PrivilegedRequest.Item(
            path: url.path, identity: try #require(FileIdentity(url: url)), allocated: 4096,
            bundleIdentifier: bundleIdentifier, requiresGone: requiresGone.map { self.url($0).path }
        )
    }

    /// The foreground check, then the child's run, in-process. Returns one line per item, checking that the file starts
    /// with this process's pid and ends with `done`.
    func execute(
        _ items: [PrivilegedRequest.Item], op: DeletionMode = .trash, beforeRename: (@Sendable (String) -> Void)? = nil
    ) throws -> [PrivilegedResultLine] {
        let folder = url("home/Library/Application Support/Macontrol/priv/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(chmod(folder.path, 0o700) == 0)
        let request = folder.appendingPathComponent("request.json")
        let data = try PrivilegedRequest(op: op, items: items).encoded()
        try data.write(to: request)
        #expect(chmod(request.path, 0o600) == 0)
        let executor = PrivilegedExecutor(testRoot: root.path, home: home.path, launchctl: launchctl, beforeRename: beforeRename)
        let checked = try executor.check(requestPath: request.path, sha256: PrivilegedRequest.sha256(data)).get()
        executor.run(checked)
        close(checked.result)
        let lines = try Data(contentsOf: folder.appendingPathComponent("result.jsonl")).split(separator: 0x0A)
            .map { try JSONDecoder().decode(PrivilegedResultLine.self, from: Data($0)) }
        #expect(lines.first?.pid == getpid() && lines.last?.done == true)
        let outcomes = lines.filter { $0.index != nil }
        #expect(outcomes.map(\.index) == Array(items.indices))
        return outcomes
    }

    /// Everything in the fixture except the Trash and macontrol's own state (journal, request folders).
    func tree() -> [String: Sandbox.Entry] {
        Sandbox.snapshot(of: tmp.url).filter { path, _ in
            !path.hasPrefix("home/.Trash/") && !path.hasPrefix("home/Library/Application Support/Macontrol/")
        }
    }

    var trashNames: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted() }
}

extension PrivilegedResultLine {
    var refusalReason: RefusalReason? {
        if case .refused(_, let reason)? = outcome(for: URL(fileURLWithPath: "/")) { reason } else { nil }
    }
}

@Suite struct PrivilegedExecutorTests {
    /// The Trash sink: each item, and only it, lands in the user's Trash as the same object, keeping its name.
    @Test func trashMovesExactlyTheCheckedItemsIntoTheUsersTrash() throws {
        let fx = try RootFixture()
        try fx.file("root/Applications/Tool.app/Contents/MacOS/Tool")
        try fx.file("root/Library/Application Support/Vendor/X/state.db")
        try fx.file("root/Library/Application Support/Vendor/Y/keep.db")
        try fx.file("root/private/var/db/receipts/com.vendor.pkg.plist")
        try fx.file("home/Library/Caches/com.vendor.app/cache.db")
        let removed = ["root/Applications/Tool.app", "root/Library/Application Support/Vendor/X",
                       "root/private/var/db/receipts/com.vendor.pkg.plist", "home/Library/Caches/com.vendor.app"]
        let items = try removed.map { try fx.item($0) }
        let before = fx.tree()

        let lines = try fx.execute(items)

        #expect(lines.map(\.status) == ["trashed", "trashed", "trashed", "trashed"], "\(lines)")
        #expect(lines.map(\.to) == removed.map { fx.trash.appendingPathComponent(($0 as NSString).lastPathComponent).path })
        let after = fx.tree()
        #expect(Sandbox.difference(after, Sandbox.expected(before, without: removed)) == [])
        for (item, line) in zip(items, lines) {
            #expect(FileIdentity(url: URL(fileURLWithPath: try #require(line.to))) == item.identity)
        }
        #expect(fx.launchctlCalls.isEmpty)
    }

    /// Finder's pattern when the Trash already has the name; what was there stays.
    @Test func aNameTheTrashHasGetsFindersTimeSuffix() throws {
        let fx = try RootFixture()
        try fx.file("root/Applications/Tool.app/Contents/Info.plist")
        let earlier = try fx.file("home/.Trash/Tool.app/Contents/old")
        let earlierIdentity = FileIdentity(url: earlier)

        let lines = try fx.execute([try fx.item("root/Applications/Tool.app")])

        let name = try #require(lines.first?.to.map { ($0 as NSString).lastPathComponent })
        #expect(name.wholeMatch(of: /Tool \d\d\.\d\d\.\d\d\.app/) != nil, "\(name)")
        #expect(FileIdentity(url: earlier) == earlierIdentity)
        #expect(PrivilegedExecutor.finderName("Tool.app", attempt: 2).wholeMatch(of: /Tool \d\d\.\d\d\.\d\d 2\.app/) != nil)
        #expect(PrivilegedExecutor.finderName("README", attempt: 1).wholeMatch(of: /README \d\d\.\d\d\.\d\d/) != nil)
    }

    /// sec 9, T-0053: a swap between the last check and the rename moves the wrong object; the identity check after
    /// the rename finds it and renames it back, so nothing the user did not confirm stays in the Trash.
    @Test func anObjectSwappedInBeforeTheRenameIsPutBack() throws {
        let fx = try RootFixture()
        let checked = try fx.file("root/Library/Application Support/Vendor/X/state.db").deletingLastPathComponent()
        let other = try fx.file("root/Library/Application Support/Vendor/Other/data.db").deletingLastPathComponent()
        let otherIdentity = FileIdentity(url: other)
        let item = try fx.item("root/Library/Application Support/Vendor/X")
        let aside = checked.deletingLastPathComponent().appendingPathComponent("X-moved")

        let lines = try fx.execute([item], beforeRename: { _ in
            rename(checked.path, aside.path)
            rename(other.path, checked.path)
        })

        #expect(lines.first?.refusalReason == .identityChanged, "\(lines)")
        #expect(fx.trashNames.isEmpty)
        #expect(FileIdentity(url: checked) == otherIdentity)
        #expect(FileIdentity(url: aside) == item.identity)
    }

    /// No leftover goes while its app is still there (sec 4); once the bundle went earlier in the request, it does.
    @Test func requiresGoneHoldsLeftoversOfAnAppThatIsStillThere() throws {
        let fx = try RootFixture()
        try fx.file("root/Applications/Tool.app/Contents/Info.plist")
        try fx.file("root/Library/Caches/com.vendor.tool/a")
        try fx.file("root/Library/Caches/com.vendor.tool2/b")
        let before = fx.tree()
        let leftover = try fx.item("root/Library/Caches/com.vendor.tool", requiresGone: "root/Applications/Tool.app")

        let kept = try fx.execute([leftover])

        #expect(kept.first?.status == "failed" && kept.first?.message == "Not removed, because Tool.app is still there.")
        #expect(Sandbox.difference(fx.tree(), before) == [])

        let bundle = try fx.item("root/Applications/Tool.app")
        let second = try fx.item("root/Library/Caches/com.vendor.tool2", requiresGone: "root/Applications/Tool.app")
        #expect(try fx.execute([bundle, second]).map(\.status) == ["trashed", "trashed"])
    }

    /// sec 11: `system/<Label>` is booted out only when `launchctl print` names this very plist. Anything else skips the
    /// bootout and still removes the file; a failed bootout keeps it. Where launchd may still run the job (it knows the
    /// label, or the label cannot be asked about), the line says it runs until the next restart (3.5 step 4, Risk 7).
    @Test(arguments: [
        ("match", "trashed", true, false), ("otherPath", "trashed", false, true), ("notLoaded", "trashed", false, false),
        ("bootoutFails", "failed", true, false), ("bootoutNotLoaded", "trashed", true, false), ("badLabel", "trashed", false, true),
        ("noLaunchctl", "trashed", false, true), ("printFails", "trashed", false, true),
    ])
    func launchDaemonIsBootedOutOnlyWhenLaunchdLoadedThisPlist(scenario: String, status: String, bootsOut: Bool, noted: Bool) throws {
        let fx = try RootFixture()
        let label = scenario == "badLabel" ? "com.vendor.helper;reboot" : "com.vendor.helper"
        let plist = try fx.tmp.file("root/Library/LaunchDaemons/com.vendor.helper.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/Library/PrivilegedHelperTools/x"], format: .xml, options: 0)
            .write(to: plist)
        let loaded = "system/com.vendor.helper = {\n\tactive count = 1\n\tpath = \(plist.path)\n\tstate = running\n}\n"
        switch scenario {
        case "otherPath": fx.printed = (0, loaded.replacingOccurrences(of: plist.path, with: plist.path + ".old"))
        case "notLoaded", "badLabel": fx.printed = (113, "Could not find service")
        // launchctl did not start, or print failed for another reason: launchd may still run the job (review 2 item 3).
        case "noLaunchctl": fx.printed = (-1, "")
        case "printFails": fx.printed = (5, "")
        default: fx.printed = (0, loaded)
        }
        fx.bootoutStatus = scenario == "bootoutFails" ? 5 : scenario == "bootoutNotLoaded" ? 3 : 0

        let lines = try fx.execute([try fx.item("root/Library/LaunchDaemons/com.vendor.helper.plist")])

        #expect(lines.first?.status == status, "\(lines)")
        let print = ["print", "system/com.vendor.helper"]
        let bootout = ["bootout", "system/com.vendor.helper"]
        #expect(fx.launchctlCalls == (scenario == "badLabel" ? [] : bootsOut ? [print, bootout] : [print]))
        #expect(FileManager.default.fileExists(atPath: plist.path) == (status == "failed"))
        #expect(lines.first?.note == (noted ? "Its background service may keep running until the next restart." : nil))
    }

    /// The same skipped bootout in permanent mode: the plist is deleted in place and the line still says so.
    @Test func aDeletedDaemonWhoseBootoutWasSkippedSaysItStillRuns() throws {
        let fx = try RootFixture()
        let plist = try fx.tmp.file("root/Library/LaunchDaemons/com.vendor.helper.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.vendor.helper"], format: .xml, options: 0).write(to: plist)
        fx.printed = (0, "system/com.vendor.helper = {\n\tstate = running\n}\n")

        let lines = try fx.execute([try fx.item("root/Library/LaunchDaemons/com.vendor.helper.plist")], op: .permanent)

        #expect(lines.map(\.status) == ["deleted"])
        #expect(lines.first?.note == PrivilegedExecutor.untilRestart)
        #expect(fx.launchctlCalls == [["print", "system/com.vendor.helper"]])
    }

    /// The app sends canonical paths, and the executor acts on the path it was sent. Another spelling of the same
    /// object (here the case of `LaunchDaemons`, on this case-insensitive disk) passes the scope and the policy, which
    /// read the canonical path, but not the LaunchDaemon check, which would skip the bootout. So it is refused.
    @Test func anotherSpellingOfADaemonIsRefused() throws {
        let fx = try RootFixture()
        let plist = try fx.tmp.file("root/Library/LaunchDaemons/com.vendor.helper.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.vendor.helper"], format: .xml, options: 0).write(to: plist)
        fx.printed = (0, "system/com.vendor.helper = {\n\tpath = \(plist.path)\n}\n")
        var item = try fx.item("root/Library/LaunchDaemons/com.vendor.helper.plist")
        item.path = fx.url("root/Library/launchdaemons/com.vendor.helper.plist").path
        try #require(FileIdentity(url: URL(fileURLWithPath: item.path)) == FileIdentity(url: plist), "needs a case-insensitive disk")
        let before = fx.tree()

        let lines = try fx.execute([item])

        #expect(lines.first?.refusalReason == .identityChanged, "\(lines)")
        #expect(fx.launchctlCalls.isEmpty)
        #expect(Sandbox.difference(fx.tree(), before) == [])
    }

    /// The root allowlist stops what the v1 policy lets a root process through: /private/etc (here a fixture file the
    /// user owns, so only the scope stands in the way), Keychains, a folder of /Applications, the user's Documents.
    @Test func itemsOutsideTheAllowlistAreRefusedUntouched() throws {
        let fx = try RootFixture()
        let paths = ["root/private/etc/sudoers", "root/Library/Keychains/login.keychain-db", "root/Applications/Vendor/readme",
                     "home/Documents/thesis.docx", "root/Library/Preferences/com.apple.loginwindow.plist"]
        for path in paths { try fx.file(path) }
        let before = fx.tree()

        let lines = try fx.execute(try paths.map { try fx.item($0) })

        #expect(lines.map(\.refusalReason) == paths.map { .protectedLocation(fx.url($0).path) })
        #expect(Sandbox.difference(fx.tree(), before) == [])
    }

    /// sec 6: the policy is the requesting user's. With root's (or anyone else's) home it would not protect this
    /// iCloud state; the item carries its bundle identifier, so only that policy can stop it.
    @Test func theRequestingUsersPolicyProtectsTheirHome() throws {
        let fx = try RootFixture()
        try fx.file("home/Library/Caches/com.apple.bird/x")
        let before = fx.tree()

        let lines = try fx.execute([try fx.item("home/Library/Caches/com.apple.bird/x", bundleIdentifier: "com.apple.bird")])

        #expect(lines.first?.refusalReason == .protectedLocation(fx.url("home/Library/Caches/com.apple.bird").path), "\(lines)")
        #expect(Sandbox.difference(fx.tree(), before) == [])
    }

    /// Only the object the user reviewed, at its canonical path: another object there, or a path through a link, stays.
    @Test func anotherObjectOrAnotherSpellingIsRefused() throws {
        let fx = try RootFixture()
        try fx.file("root/Library/Caches/Vendor/a")
        try fx.file("root/Library/Caches/Real/b")
        try fx.tmp.symlink("home/Library/Caches/Linked", to: fx.url("root/Library/Caches/Real").path)
        var stale = try fx.item("root/Library/Caches/Vendor")
        stale.inode += 1
        var linked = try fx.item("root/Library/Caches/Real/b")
        linked.path = fx.url("home/Library/Caches/Linked/b").path
        let before = fx.tree()

        let lines = try fx.execute([stale, linked])

        #expect(lines.map(\.refusalReason) == [.identityChanged, .identityChanged])
        #expect(Sandbox.difference(fx.tree(), before) == [])
    }

    /// Root never clears a flag: a file the user locked keeps its whole folder where it is.
    @Test func aLockedFileInsideKeepsTheWholeItem() throws {
        let fx = try RootFixture()
        let locked = try fx.file("root/Library/Caches/Vendor/sub/locked.db")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        // Keeps the fixture alive until the flag is cleared, so its folder can remove itself.
        defer { withExtendedLifetime(fx) { _ = chflags(locked.path, 0) } }
        let before = fx.tree()

        let lines = try fx.execute([try fx.item("root/Library/Caches/Vendor")])

        #expect(lines.first?.refusalReason == .holdsLocked("sub/locked.db"))
        #expect(Sandbox.difference(fx.tree(), before) == [])
    }

    /// App Management answers EPERM when an app bundle it guards is moved, which is the helper's main job (Apple's App
    /// Store apps in /Applications). The helper says what the in-process move says, in both modes; other items keep
    /// the system's words. A user-set UF_IMMUTABLE after the checks gives the same EPERM (T-0075 review 2 item 1).
    @Test(arguments: [DeletionMode.trash, .permanent])
    func anAppMacOSWillNotLetGoSaysAppManagement(op: DeletionMode) throws {
        let fx = try RootFixture()
        try fx.file("root/Applications/Tool.app/Contents/MacOS/Tool")
        try fx.file("root/Library/Application Support/Vendor/X/state")
        let paths = ["root/Applications/Tool.app", "root/Library/Application Support/Vendor/X"].map { fx.url($0).path }
        defer { withExtendedLifetime(fx) { paths.forEach { _ = chflags($0, 0) } } }
        let before = fx.tree()

        let lines = try fx.execute(try ["root/Applications/Tool.app", "root/Library/Application Support/Vendor/X"].map { try fx.item($0) },
                                   op: op, beforeRename: { _ = chflags($0, UInt32(UF_IMMUTABLE)) })

        #expect(lines.map(\.status) == ["failed", "failed"], "\(lines)")
        #expect(lines.map(\.message) == [TrashBatch.appManagementBlocked, "Operation not permitted"])
        paths.forEach { _ = chflags($0, 0) }
        #expect(Sandbox.difference(fx.tree(), before) == [])
    }

    /// As root, "needs an administrator" can only mean privacy protection or SIP, so after the password the helper
    /// never says it (T-0075 review 2 item 4). A folder this user cannot write stands in for one root cannot reach.
    @Test func whatRootCannotReachIsNotCalledAdminOnly() throws {
        let fx = try RootFixture()
        let sub = try fx.file("root/Library/Application Support/Vendor/X/sub/state").deletingLastPathComponent()
        #expect(chmod(sub.path, 0o555) == 0)
        defer { withExtendedLifetime(fx) { _ = chmod(sub.path, 0o755) } }
        let before = fx.tree()

        let lines = try fx.execute([try fx.item("root/Library/Application Support/Vendor/X")], op: .permanent)

        #expect(lines.first?.status == "failed" && lines.first?.message == PrivilegedExecutor.rootKeptOut, "\(lines)")
        #expect(Sandbox.difference(fx.tree(), before) == [])
    }

    /// Without a Trash the user owns, nothing moves.
    @Test func noUsableTrashMovesNothing() throws {
        let fx = try RootFixture()
        try fx.file("root/Library/Caches/Vendor/a")
        try FileManager.default.removeItem(at: fx.trash)
        try fx.tmp.symlink("home/.Trash", to: fx.url("root/Library/Caches").path)
        let before = fx.tree()

        let lines = try fx.execute([try fx.item("root/Library/Caches/Vendor")])

        #expect(lines.first?.message == "Your Trash folder could not be opened, so nothing was moved.")
        #expect(Sandbox.difference(fx.tree(), before) == [])
    }

    /// D3: permanent = the Trash move, then the engine's erase of the trashed copy.
    @Test func permanentDeletesAfterTheTrashMove() throws {
        let fx = try RootFixture()
        try fx.file("root/Library/Application Support/Vendor/X/state.db")
        let before = fx.tree()

        let lines = try fx.execute([try fx.item("root/Library/Application Support/Vendor/X")], op: .permanent)

        #expect(Sandbox.difference(fx.tree(), Sandbox.expected(before, without: ["root/Library/Application Support/Vendor/X"])) == [])
        #expect(lines.first?.status == "deleted", "\(lines)")
        #expect(fx.trashNames.isEmpty)
    }

    /// D12: an erase that removed nothing leaves the item whole in the Trash. Root moved it, so its History line has no
    /// Undo: the message sends the user to Finder, never to History's Undo (v1's `TrashBatch.notDeleted`).
    @Test func aFailedEraseSendsTheUserToFinderNotToUndo() throws {
        let fx = try RootFixture()
        try fx.file("root/Library/Caches/Vendor/sub/file")
        let item = try fx.item("root/Library/Caches/Vendor")
        let trashed = fx.trash.appendingPathComponent("Vendor")
        defer { _ = chmod(trashed.appendingPathComponent("sub").path, 0o755) }

        // After every check, before the rename: the erase of the trashed copy then cannot remove anything.
        let lines = try fx.execute([item], op: .permanent, beforeRename: { [sub = fx.url("root/Library/Caches/Vendor/sub").path] _ in
            _ = chmod(sub, 0o555)
        })

        let line = try #require(lines.first)
        #expect(line.status == "failed" && line.to == trashed.path, "\(line)")
        #expect(line.message?.contains("drag it back from the Trash in Finder") == true, "\(line)")
        #expect(line.message?.contains("Undo") == false)
        let entry = try #require(PrivilegedRouting.journalEntry(line, item, batch: UUID(), restorePoint: nil))
        #expect(entry.asAdministrator && entry.trashedPath == trashed.path)
    }

    /// D3: a file is one unlinkat in place, never a Trash move; D4: a personal database goes to the Trash even in
    /// permanent mode, and is not erased there.
    @Test func permanentDeletesAFileInPlaceAndKeepsPersonalDataInTheTrash() throws {
        let fx = try RootFixture()
        try fx.file("root/Library/Logs/com.vendor.app.log")
        try fx.file("home/Library/Application Support/AddressBook/Sources/card.abcdp")
        let before = fx.tree()

        let lines = try fx.execute([
            try fx.item("root/Library/Logs/com.vendor.app.log"), try fx.item("home/Library/Application Support/AddressBook"),
        ], op: .permanent)

        #expect(lines.map(\.status) == ["deleted", "trashed"], "\(lines)")
        #expect(fx.trashNames == ["AddressBook"])
        let removed = ["root/Library/Logs/com.vendor.app.log", "home/Library/Application Support/AddressBook"]
        #expect(Sandbox.difference(fx.tree(), Sandbox.expected(before, without: removed)) == [])
    }

    /// Scope, then the policy, on this Mac's real paths (read-only: only the checks run). sec 3b's systemNeverTouch
    /// additions are permanent-engine's; until they merge, the policy says "needs an administrator" for
    /// SystemConfiguration, and as root nothing would stop it.
    @Test(arguments: [
        ("/Library/Preferences/SystemConfiguration/preferences.plist", "/Library/Preferences/SystemConfiguration", true),
        ("/Library/Application Support/Apple/ParentalControls", "/Library/Application Support/Apple/ParentalControls", false),
        // macOS's printer list: root-owned, no flags, no rootless attribute, and an app may claim its name (review 2).
        ("/Library/Preferences/org.cups.printers.plist", "/Library/Preferences/org.cups.printers.plist", false),
    ])
    func liveConfigurationIsAProtectedLocation(path: String, place: String, waitsForTheEngine: Bool) throws {
        let fx = try RootFixture()
        guard let identity = FileIdentity(url: URL(fileURLWithPath: path)) else { return }
        let executor = PrivilegedExecutor(testRoot: "/", home: fx.home.path, launchctl: fx.launchctl)
        let refusal = executor.refusal(of: .init(path: path, identity: identity), home: fx.home.path, policy: PrivilegedExecutor.policy(home: fx.home.path))
        #expect(refusal == .refused(.protectedLocation(place)), "engine additions: \(waitsForTheEngine)")
    }
}
