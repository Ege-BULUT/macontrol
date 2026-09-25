import Darwin
import Foundation
import MacontrolCore
@testable import Safety
import Testing

/// The v1 attacks on the one door, run again in permanent mode (DESIGN-debloat section 2.7), and the r2 cases: a
/// partial erase, and the three passes of `remove` against a stand-in for the administrator helper. Each test compares
/// the whole sandbox before and after: exactly the intended items (and what they hold) are gone. There is no Undo to
/// run afterwards, so the remover used here stops the test process before it could touch anything outside the sandbox.
@Suite struct PermanentAttackTests {
    let box: Sandbox
    let caches = "home/Library/Caches"

    init() throws {
        box = try Sandbox()
    }

    func item(_ relative: String, keep: [URL] = [], requiresGone: URL? = nil) -> TrashItem {
        TrashItem(url: box.url(relative), expectedIdentity: FileIdentity(url: box.url(relative)), keep: keep, requiresGone: requiresGone)
    }

    /// The sandbox's own Trash backend and journal, a guarded remover with an optional hook, and a stand-in route.
    func service(
        hook: (@Sendable (_ item: String, _ relative: String) -> Void)? = nil, route: TrashService.Route? = nil
    ) async -> TrashService {
        let root = box.tmp.url.path + "/"
        let engine = RemovalEngine { item, relative in
            precondition(item.hasPrefix(root), "a permanent delete outside the sandbox: \(item)")
            hook?(item, relative)
        }
        let unrouted: TrashService.Route = { items, _, _, _, _, _, _ in (items.map { .refused($0.url, .needsAdministrator) }, [:]) }
        return TrashService(journalURL: box.journal, backend: await box.service().backend, home: box.home, engine: engine, route: route ?? unrouted)
    }

    /// Deletes `items` permanently and expects exactly `intended` (and what they hold) to have left the sandbox.
    @discardableResult
    func expectOnly(
        _ intended: [String], leaveWhenDeleting items: [TrashItem], cloudConfirmed: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> TrashReport {
        let before = box.tree()
        let report = await service().remove(items, mode: .permanent, cloudConfirmed: cloudConfirmed)
        let stray = Sandbox.difference(box.tree(), Sandbox.expected(before, without: intended))
        #expect(stray == [], "deleted something it should not have, or kept something it should have deleted", sourceLocation: sourceLocation)
        return report
    }

    /// What the sandbox's Trash still holds, by path below each move's own folder (`<name>/...`).
    func inTrash() -> [String] {
        Sandbox.snapshot(of: box.trashFolder).keys.compactMap { path in
            let parts = path.split(separator: "/", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : nil
        }.sorted()
    }

    func expectNoCommandRan(sourceLocation: SourceLocation = #_sourceLocation) {
        for folder in [box.tmp.url, box.home, box.url(caches), URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            #expect(!names.contains { $0.hasPrefix("PWNED") }, "a command ran in \(folder.path)", sourceLocation: sourceLocation)
        }
    }

    // MARK: v1 attacks, permanent

    @Test func hostileNamesGoAsThemselves() async throws {
        for name in HostileNames.shell + [HostileNames.lookalike, HostileNames.decomposed, "Cache", "cafe", "rf", "touch"] {
            try box.file("\(caches)/\(name)/data")
            try box.file("\(caches)/\(name)-file")
        }
        let chosen = HostileNames.shell.flatMap { [$0, "\($0)-file"] } + [HostileNames.lookalike, "caf\u{00E9}"]

        let report = await expectOnly(chosen.map { "\(caches)/\($0)" }, leaveWhenDeleting: chosen.map { item("\(caches)/\($0)") })

        #expect(report.outcomes.map(\.deletedPath) == chosen.map { box.url("\(caches)/\($0)").path }, "\(report.outcomes)")
        let history = await box.service().history()
        #expect(history.count == chosen.count && history.allSatisfy { $0.isPermanent && $0.batch == report.batch })
        #expect(inTrash().isEmpty)
        expectNoCommandRan()
    }

    @Test func protectedPlacesNeverGo() async throws {
        try box.file("home/.ssh/id_ed25519")
        try box.file("home/Documents/thesis.docx")
        try box.file("home/Library/Keychains/login.keychain-db")
        try box.file("home/.Trash/old.zip")
        try box.file("home/Library/Mobile Documents/com~apple~CloudDocs/notes.txt")
        try box.file("\(caches)/com.example.ordinary/blob")
        try FileManager.default.createSymbolicLink(atPath: box.url("\(caches)/sneaky").path, withDestinationPath: "../../.ssh")
        try FileManager.default.createSymbolicLink(at: box.url("\(caches)/docs"), withDestinationURL: box.url("home/Documents"))
        let attacks = [
            "home", "home/Library", "home/Library/Caches", "home/Documents", "home/.ssh", "home/.ssh/id_ed25519",
            "home/Library/Keychains", "home/Library/Keychains/login.keychain-db", "home/.Trash", "home/.Trash/old.zip",
            "home/Library/Mobile Documents", "home/Library/Mobile Documents/com~apple~CloudDocs",
            "\(caches)/../../Documents", "\(caches)/sneaky/.", "\(caches)/sneaky/id_ed25519", "\(caches)/docs/.", "\(caches)/..",
        ].map { TrashItem(url: box.url($0), expectedIdentity: nil) }
        let items = attacks + [
            TrashItem(url: URL(fileURLWithPath: box.tmp.url.path), expectedIdentity: nil),
            TrashItem(url: URL(fileURLWithPath: "/System/Volumes/Data" + box.url("home/Documents").path), expectedIdentity: nil),
            item("\(caches)/com.example.ordinary"),
        ]

        let report = await expectOnly(["\(caches)/com.example.ordinary"], leaveWhenDeleting: items, cloudConfirmed: true)

        #expect(report.outcomes.filter { $0.refusal != nil }.count == items.count - 1, "\(report.outcomes)")
        #expect(box.backendCalls.map(\.lastPathComponent) == ["com.example.ordinary"])
    }

    @Test func aSelectedLinkGoesAsTheLink() async throws {
        try box.file("home/.ssh/id_ed25519")
        try box.file("home/Documents/thesis.docx", size: 1 << 20)
        let links = ["to-docs": box.url("home/Documents").path, "to-ssh": "../../.ssh", "to-file": box.url("home/Documents/thesis.docx").path, "dangling": "/nonexistent-macontrol"]
        for (name, destination) in links {
            try FileManager.default.createSymbolicLink(atPath: box.url("\(caches)/\(name)").path, withDestinationPath: destination)
        }
        let chosen = links.keys.sorted().map { "\(caches)/\($0)" }

        let report = await expectOnly(chosen, leaveWhenDeleting: chosen.map { item($0) })

        #expect(report.outcomes == chosen.map { .deleted(original: box.url($0)) })
        #expect(box.backendCalls.isEmpty, "a link is deleted in place")
    }

    @Test func hardLinksOutsideTheSelectionKeepTheirData() async throws {
        let thesis = try box.file("home/Documents/big.bin", size: 1 << 20)
        try Data(repeating: 0x5A, count: 1 << 20).write(to: thesis)
        try box.file("home/.ssh/id_ed25519")
        try box.tmp.hardLink("\(caches)/com.example.links/big.bin", to: "home/Documents/big.bin")
        try box.tmp.hardLink("\(caches)/com.example.links/key", to: "home/.ssh/id_ed25519")
        try box.tmp.hardLink("\(caches)/single.bin", to: "home/Documents/big.bin")

        await expectOnly(["\(caches)/com.example.links", "\(caches)/single.bin"], leaveWhenDeleting: [item("\(caches)/com.example.links"), item("\(caches)/single.bin")])

        #expect(try Data(contentsOf: thesis) == Data(repeating: 0x5A, count: 1 << 20))
    }

    @Test func aSwapAfterTheScanIsRefused() async throws {
        try box.file("\(caches)/com.example.swapped/blob")
        try box.file("\(caches)/com.example.parent/blob")
        try box.file("home/Documents/thesis.docx")
        try box.file("home/Documents/proj/blob")
        let items = [item("\(caches)/com.example.swapped"), item("\(caches)/com.example.parent/blob")]
        try box.swapForSymlink("\(caches)/com.example.swapped", to: box.url("home/Documents"))
        try box.swapForSymlink("\(caches)/com.example.parent", to: box.url("home/Documents/proj"))

        let report = await expectOnly([], leaveWhenDeleting: items)

        #expect(report.outcomes.map(\.refusal) == [.identityChanged, .identityChanged])
        #expect(box.backendCalls.isEmpty)
    }

    @Test func aSwapDuringTheBatchIsRefused() async throws {
        try box.file("\(caches)/com.example.first/blob")
        try box.file("\(caches)/com.example.second/data.bin")
        try box.file("home/Documents/proj/data.bin")
        let items = [item("\(caches)/com.example.first"), item("\(caches)/com.example.second/data.bin")]
        box.beforeEachMove { box, url in
            if url.lastPathComponent == "com.example.first" {
                try? box.swapForSymlink("home/Library/Caches/com.example.second", to: box.url("home/Documents/proj"))
            }
        }
        let documents = box.tree().filter { $0.key.hasPrefix("home/Documents") }

        let report = await service().remove(items, mode: .permanent)

        #expect(report.outcomes.map(\.deletedPath) == [box.url("\(caches)/com.example.first").path, nil])
        #expect(report.outcomes.last?.refusal == .identityChanged)
        #expect(box.tree().filter { $0.key.hasPrefix("home/Documents") } == documents)
    }

    /// A file goes in place, so the swap lands between the last check and the delete: the file's folder becomes a
    /// link to a project holding another name of the same file. The delete opens the folder refusing any link on the
    /// way, so the project's name stays.
    @Test func aSwapJustBeforeAnInPlaceDeleteMustNotReachTheLinkedFile() async throws {
        // One inode under both names, so the identity check alone passes the Documents name (T-0054).
        try box.file("\(caches)/com.example.window/data.bin")
        try box.tmp.hardLink("home/Documents/proj/data.bin", to: "\(caches)/com.example.window/data.bin")
        let documents = box.tree().filter { $0.key.hasPrefix("home/Documents") }
        let service = await service(hook: { [box] _, relative in
            if relative.isEmpty { try? box.swapForSymlink("home/Library/Caches/com.example.window", to: box.url("home/Documents/proj")) }
        })

        let report = await service.remove([item("\(caches)/com.example.window/data.bin")], mode: .permanent)

        #expect(report.outcomes.map(\.refusal) == [.identityChanged])
        #expect(box.tree().filter { $0.key.hasPrefix("home/Documents") } == documents, "Documents/proj/data.bin was deleted")
        #expect(await box.service().history().isEmpty)
    }

    /// A folder goes to the Trash first, and the move follows a link swapped in on the way, so another folder reaches
    /// the Trash. It is put back and never erased; when it cannot go back it stays whole in the Trash, journaled for
    /// Undo (T-0053).
    @Test(arguments: [false, true])
    func aFolderSwappedInsideTheMoveIsNeverErased(blockedOnTheWayBack: Bool) async throws {
        try box.file("\(caches)/com.example.window/data/cache.bin")
        try box.file("home/Documents/proj/data/thesis.docx", size: 777)
        box.beforeEachMove { box, _ in
            try? box.swapForSymlink("home/Library/Caches/com.example.window", to: box.url("home/Documents/proj"))
        }
        if blockedOnTheWayBack {
            box.afterEachMove { box, _ in _ = try? box.tmp.directory("home/Documents/proj/data") }
        }

        let service = await service()
        let report = await service.remove([item("\(caches)/com.example.window/data")], mode: .permanent)

        if blockedOnTheWayBack {
            guard case .failed? = report.outcomes.first else { Issue.record("\(report.outcomes)"); return }
            #expect(inTrash().contains("data/thesis.docx"), "the folder that reached the Trash was erased")
            #expect(await service.history().map(\.isPermanent) == [false], "journaled as trashed, for Undo")
        } else {
            #expect(report.outcomes.map(\.refusal) == [.identityChanged])
            #expect(FileManager.default.fileExists(atPath: box.url("home/Documents/proj/data/thesis.docx").path))
            #expect(await service.history().isEmpty)
        }
    }

    @Test func aSwapOntoAHardLinkIsRefused() async throws {
        try box.file("home/Documents/proj/blob")
        try box.tmp.hardLink("\(caches)/com.example.shared/blob", to: "home/Documents/proj/blob")
        let selected = item("\(caches)/com.example.shared/blob")
        try box.swapForSymlink("\(caches)/com.example.shared", to: box.url("home/Documents/proj"))

        let report = await expectOnly([], leaveWhenDeleting: [selected])

        #expect(report.outcomes.map(\.refusal) == [.identityChanged])
    }

    @Test func systemSpellingsOfAPathStillGo() async throws {
        try box.file("\(caches)/com.example.case/blob")
        try box.file("\(caches)/com.example.data/blob")
        try box.file("\(caches)/cafe\u{0301}/blob")
        let items = [
            TrashItem(url: box.url("home/library/CACHES/COM.EXAMPLE.CASE"), expectedIdentity: nil),
            TrashItem(url: URL(fileURLWithPath: "/System/Volumes/Data" + box.url("\(caches)/com.example.data").path), expectedIdentity: nil),
            TrashItem(url: box.url("\(caches)/caf\u{00E9}"), expectedIdentity: nil),
        ]

        let report = await expectOnly(["\(caches)/com.example.case", "\(caches)/com.example.data", "\(caches)/cafe\u{0301}"], leaveWhenDeleting: items)

        #expect(report.outcomes == items.map { .deleted(original: $0.url) }, "\(report.outcomes)")
    }

    @Test func lockedItemsAreRefusedAndStayLocked() async throws {
        try box.file("\(caches)/com.example.lockedfile/blob")
        try box.file("\(caches)/com.example.lockedfolder/blob")
        try box.file("\(caches)/com.example.inlocked/blob")
        for path in ["com.example.lockedfile/blob", "com.example.lockedfolder", "com.example.inlocked"] {
            #expect(chflags(box.url("\(caches)/\(path)").path, UInt32(UF_IMMUTABLE)) == 0)
        }
        let items = [item("\(caches)/com.example.lockedfile/blob"), item("\(caches)/com.example.lockedfolder"), item("\(caches)/com.example.inlocked/blob")]

        let report = await expectOnly([], leaveWhenDeleting: items)

        #expect(report.outcomes.map(\.refusal) == [.locked, .locked, .locked])
    }

    /// A locked file one and two levels deep stops its folder before anything goes; an unlocked folder next to it goes.
    @Test func aLockedFileDeepInsideStopsItsFolderBeforeAnythingGoes() async throws {
        try box.file("\(caches)/com.example.holder/junk.bin")
        try box.file("\(caches)/com.example.holder/keepsake.txt")
        try box.file("\(caches)/com.example.deeper/a/b/keepsake.txt")
        try box.file("\(caches)/com.example.deeper/a/junk.bin")
        try box.file("\(caches)/com.example.plain/junk.bin")
        for path in ["com.example.holder/keepsake.txt", "com.example.deeper/a/b/keepsake.txt"] {
            #expect(chflags(box.url("\(caches)/\(path)").path, UInt32(UF_IMMUTABLE)) == 0)
        }
        let items = ["com.example.holder", "com.example.deeper", "com.example.plain"].map { item("\(caches)/\($0)") }

        let report = await expectOnly(["\(caches)/com.example.plain"], leaveWhenDeleting: items)

        #expect(report.outcomes.map(\.refusal) == [.holdsLocked("keepsake.txt"), .holdsLocked("a/b/keepsake.txt"), nil])
    }

    // MARK: Unchecked children (keep)

    @Test func uncheckedChildrenSurviveHoweverTheyAreSpelled() async throws {
        let project = "\(caches)/com.example.project"
        try box.file("\(project)/src/main.swift")
        try box.file("\(project)/build/out.o", size: 1 << 16)
        try box.file("\(project)/NOTES.md")
        try box.file("\(project)/.git/HEAD")
        try box.file("\(project)/loose.txt")
        try FileManager.default.createSymbolicLink(at: box.url("\(caches)/alias"), withDestinationURL: box.url(project))
        let keep = [box.url("\(caches)/alias/src"), box.url("\(caches)/COM.EXAMPLE.PROJECT/notes.MD")]

        let report = await expectOnly(["\(project)/build", "\(project)/.git", "\(project)/loose.txt"], leaveWhenDeleting: [item(project, keep: keep)])

        #expect(report.outcomes.count == 3 && report.outcomes.allSatisfy { $0.isDone } && !report.outcomes.contains(where: \.isTrashed), "\(report.outcomes)")
    }

    /// A deselection wins over every other selected item, from below and from above, and a duplicate or nested
    /// selection is deleted once.
    @Test func keepHoldsAgainstOtherSelectionsAndDuplicatesGoOnce() async throws {
        let root = "\(caches)/com.example.old"
        try box.file("\(root)/build.log")
        try box.file("\(root)/src/main.c")
        let kept = try box.file("\(root)/src/notes.md")
        try box.file("\(caches)/dup.bin")
        try box.file("\(caches)/big/inner/blob.bin")

        let report = await expectOnly(["\(root)/build.log", "\(root)/src/main.c", "\(caches)/dup.bin", "\(caches)/big"], leaveWhenDeleting: [
            item(root, keep: [kept]), item("\(root)/src"), item("\(root)/src/notes.md"),
            item("\(caches)/dup.bin"), TrashItem(url: box.url("\(caches)/DUP.BIN"), expectedIdentity: nil),
            item("\(caches)/big/inner/blob.bin"), item("\(caches)/big"),
        ])

        let last = ["dup.bin", "DUP.BIN", "big/inner/blob.bin", "big"].map { box.url("\(caches)/\($0)").path }
        #expect(report.outcomes.suffix(4).map(\.deletedPath) == last, "\(report.outcomes)")
        #expect(box.backendCalls.map(\.lastPathComponent) == ["big"], "a folder once, files in place")
        #expect(await box.service().history().count == 4, "old/build.log, old/src/main.c, dup.bin, big")
    }

    /// A kept path whose folder cannot be opened stops its item (fail closed); a folder spelled in another case keeps
    /// its unchecked child; a folder whose every child is kept deletes nothing and says so under its own URL.
    @Test func keepFailsClosedAndMatchesAnySpelling() async throws {
        let locked = "\(caches)/com.example.private"
        try box.file("\(locked)/build.log")
        let hidden = try box.file("\(locked)/private/keep-me.txt")
        #expect(chmod(hidden.deletingLastPathComponent().path, 0o300) == 0)
        defer { chmod(hidden.deletingLastPathComponent().path, 0o755) }
        let spelled = "\(caches)/com.example.old"
        try box.file("\(spelled)/build.log")
        let kept = try box.file("\(spelled)/src/notes.md")
        let full = "\(caches)/com.example.full"
        let only = try box.file("\(full)/notes.md")

        let blocked = await expectOnly([], leaveWhenDeleting: [item(locked, keep: [hidden])])
        let report = await expectOnly(["\(spelled)/build.log"], leaveWhenDeleting: [
            TrashItem(url: box.url("\(caches)/COM.EXAMPLE.OLD"), expectedIdentity: nil, keep: [kept]),
            TrashItem(url: box.url(full), expectedIdentity: nil, keep: [only]),
        ])

        guard case .failed? = blocked.outcomes.first else { Issue.record("\(blocked.outcomes)"); return }
        #expect(report.outcomes.map(\.deletedPath) == [box.url("\(caches)/COM.EXAMPLE.OLD/build.log").path, nil])
        guard case .failed(let url, _)? = report.outcomes.last else { Issue.record("\(report.outcomes)"); return }
        #expect(url.path == box.url(full).path)
    }

    @Test func aKeptPathPastPathMaxStopsTheWholeBatch() async throws {
        let chain = try box.deepChain("\(caches)/com.example.deepkeep/tree")
        try box.file("\(caches)/com.example.deepkeep/junk.bin")
        try box.file("\(caches)/com.example.other/junk.bin")

        let report = await expectOnly([], leaveWhenDeleting: [item("\(caches)/com.example.deepkeep", keep: [box.url(chain.leaf)]), item("\(caches)/com.example.other")])

        #expect(report.outcomes.allSatisfy { if case .failed = $0 { true } else { false } })
    }

    /// A chain deeper than PATH_MAX goes whole; an item that is itself past PATH_MAX is refused untouched.
    @Test func deepTreesGoWholeAndDeepItemsAreRefused() async throws {
        let chain = try box.deepChain("\(caches)/com.example.deep")
        let deeper = try box.deepChain("\(caches)/com.example.deeper")

        await expectOnly(["\(caches)/com.example.deep"], leaveWhenDeleting: [item("\(caches)/com.example.deep")])
        let report = await expectOnly([], leaveWhenDeleting: [TrashItem(url: box.url(deeper.leaf), expectedIdentity: nil)])

        #expect(report.outcomes.map(\.refusal) == [.needsAdministrator])
        #expect(box.tree()[chain.leaf] == nil && inTrash().isEmpty)
    }

    @Test func aLinkedJournalStopsTheBatch() async throws {
        let keys = try box.file("home/.ssh/authorized_keys", size: 100)
        try box.tmp.directory("state")
        try FileManager.default.createSymbolicLink(at: box.journal, withDestinationURL: keys)
        try box.file("\(caches)/com.example.victim/blob")
        try box.file("\(caches)/victim.bin")

        let report = await expectOnly([], leaveWhenDeleting: [item("\(caches)/com.example.victim"), item("\(caches)/victim.bin")])

        #expect(report.outcomes.allSatisfy { if case .failed = $0 { true } else { false } })
        #expect(try Data(contentsOf: keys) == Data(count: 100))
    }

    /// The journal, its folder and the folder holding that are refused; so are an identity that changed since the
    /// scan and a cloud item without confirmation.
    @Test func theJournalChangedItemsAndUnconfirmedCloudItemsAreRefused() async throws {
        try box.file("\(caches)/a.tmp")
        _ = await service().remove([item("\(caches)/a.tmp")], mode: .permanent)
        let scanned = try box.file("\(caches)/setup.dmg")
        let identity = FileIdentity(url: scanned)
        try FileManager.default.removeItem(at: scanned)
        try box.file("\(caches)/setup.dmg", size: 20)
        try box.file("home/Library/Mobile Documents/com~apple~CloudDocs/Notes.txt")
        let folder = box.journal.deletingLastPathComponent()

        let report = await expectOnly([], leaveWhenDeleting: [
            TrashItem(url: box.journal, expectedIdentity: nil), TrashItem(url: folder, expectedIdentity: nil),
            TrashItem(url: folder.deletingLastPathComponent(), expectedIdentity: nil),
            TrashItem(url: scanned, expectedIdentity: identity), item("home/Library/Mobile Documents/com~apple~CloudDocs/Notes.txt"),
        ])

        #expect(report.outcomes.prefix(3).allSatisfy { if case .protectedLocation? = $0.refusal { true } else { false } }, "\(report.outcomes)")
        #expect(report.outcomes.suffix(2).map(\.refusal) == [.identityChanged, .needsCloudConfirmation])
    }

    // MARK: r2: partial erase (sec 4)

    /// Entry 501 of 1,000 is where the erase starts failing (the folder turns read-only under it, as App Management or
    /// a lock would): the original path is gone, and the other 500 wait in the Trash under the folder's name.
    @Test func anEraseThatStopsHalfwayLeavesTheRestInTheTrash() async throws {
        let big = "\(caches)/com.example.big"
        let folder = try box.tmp.directory(big)
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY)
        for index in 0..<1000 { close(openat(fd, String(format: "f%04d", index), O_WRONLY | O_CREAT, 0o644)) }
        close(fd)
        let seen = Counter()
        let service = await service(hook: { item, relative in
            if !relative.isEmpty, seen.next() == 501 { chmod(item, 0o555) }
        })
        let before = box.tree()

        let report = await service.remove([item(big)], mode: .permanent)

        #expect(Sandbox.difference(box.tree(), Sandbox.expected(before, without: [big])) == [], "the original path must be empty")
        let left = inTrash()
        #expect(left.count == 501 && left.first == "com.example.big", "\(left.count) left")
        guard case .failed(_, let message)? = report.outcomes.first else { Issue.record("\(report.outcomes)"); return }
        #expect(message.hasPrefix("Partly deleted. 500 items inside could not be removed; the rest is in the Trash as \"com.example.big\". Empty the Trash to finish. First: f"), "\(message)")
        #expect(message.hasSuffix(": Permission denied"), "\(message)")
        #expect(await box.service().history().map(\.isPermanent) == [true], "bytes were removed, so History shows it")
    }

    /// Every entry refuses to go (the folder turns read-only before the first, as App Management would): nothing was
    /// deleted, so the outcome must not say so, and the folder, whole in the Trash, keeps its Undo (T-0074 review 2).
    @Test func anEraseThatRemovesNothingKeepsItsUndo() async throws {
        let whole = "\(caches)/com.example.whole"
        for index in 0..<5 { try box.file("\(whole)/f\(index)", size: 10) }
        let seen = Counter()
        let service = await service(hook: { item, relative in
            if !relative.isEmpty, seen.next() == 1 { chmod(item, 0o555) }
        })
        let before = box.tree()

        let report = await service.remove([item(whole)], mode: .permanent)

        #expect(inTrash() == ["com.example.whole"] + (0..<5).map { "com.example.whole/f\($0)" })
        guard case .failed(_, let message)? = report.outcomes.first, report.outcomes.count == 1 else { Issue.record("\(report.outcomes)"); return }
        // The first entry named depends on the listing's order.
        #expect(message.hasPrefix("Moved to the Trash as \"com.example.whole\", but nothing in it could be deleted (f"), "\(message)")
        #expect(message.hasSuffix(": Permission denied). Undo it from History, or empty the Trash to finish."), "\(message)")
        let history = await box.service().history()
        let trashed = try #require(history.first?.trashedPath, "journaled as trashed, not as deleted")
        chmod(trashed, 0o755)
        let undone = await box.service().undo(batch: report.batch)
        #expect(undone.count == 1 && undone.allSatisfy { if case .restored = $0 { true } else { false } }, "\(undone)")
        #expect(Sandbox.difference(box.tree(), before) == [])
    }

    /// The Trash folder (for a folder) or the item's own folder (for a file) cannot be opened when the delete starts,
    /// as with TCC or a permission change: that is a failure with its reason, not "it changed" (T-0074 review 4).
    @Test(arguments: [false, true])
    func aFolderThatCannotBeOpenedIsAFailureNotAChange(isFile: Bool) async throws {
        let relative = isFile ? "\(caches)/com.example.tcc/blob" : "\(caches)/com.example.tcc"
        try box.file("\(caches)/com.example.tcc/blob", size: 10)
        let blocked = Calls()
        let service = await service(hook: { item, relative in
            guard relative.isEmpty else { return }
            let folder = (item as NSString).deletingLastPathComponent
            blocked.record([folder])
            chmod(folder, 0o000)
        })
        let before = box.tree()

        let report = await service.remove([item(relative)], mode: .permanent)

        for call in blocked.all { chmod(call[0], 0o755) }
        guard case .failed(_, let message)? = report.outcomes.first else { Issue.record("\(report.outcomes)"); return }
        if isFile {
            #expect(message == "It could not be deleted: Permission denied.")
            #expect(box.tree() == before)
        } else {
            #expect(message.hasPrefix("Moved to the Trash as \"com.example.tcc\", but nothing in it could be deleted (com.example.tcc: Permission denied)."), "\(message)")
            #expect(await box.service().undo(batch: report.batch).count == 1)
            #expect(Sandbox.difference(box.tree(), before) == [])
        }
    }

    // MARK: r2: the three passes of remove (section 3.6, ux 9, sec 4)

    /// A root-owned app (a 0555 bundle stands in) with two leftovers that wait for it, and an ordinary cache between
    /// them. Pass 1 removes the cache and sets the bundle aside; the helper stand-in gets the bundle alone, while the
    /// leftovers are still in place; pass 3 removes them once the bundle is gone. Outcomes stay in item order.
    @Test(arguments: [DeletionMode.trash, .permanent])
    func threePassesInOrder(mode: DeletionMode) async throws {
        let bundle = try box.tmp.directory("root/Applications/Example.app")
        try box.file("root/Applications/Example.app/Contents/Info.plist")
        #expect(chmod(bundle.path, 0o555) == 0)
        try box.file("\(caches)/com.example.app/blob")
        try box.file("home/Library/Preferences/com.example.app.plist")
        try box.file("\(caches)/com.other/blob")
        let items = [
            item("root/Applications/Example.app"), item("\(caches)/com.example.app", requiresGone: bundle),
            item("\(caches)/com.other"), item("home/Library/Preferences/com.example.app.plist", requiresGone: bundle),
        ]
        let calls = Calls()
        let box = box
        let route: TrashService.Route = { routed, routedMode, _, _, _, _, _ in
            calls.record(routed.map(\.url.lastPathComponent) + [
                "mode \(routedMode)", "cache gone \(FileIdentity(url: box.url("home/Library/Caches/com.other")) == nil)",
                "leftovers there \(routed.isEmpty ? false : FileIdentity(url: box.url("home/Library/Caches/com.example.app")) != nil)",
            ])
            // What the helper does as root, done here as the owner: the bundle leaves its place.
            chmod(bundle.path, 0o755)
            try? FileManager.default.moveItem(at: bundle, to: box.trashFolder.appendingPathComponent("Example.app"))
            // The helper's note on an item that went (a LaunchDaemon it did not stop) reaches the report.
            return (routed.map { .deleted(original: $0.url) }, routed.first.map { [$0.url: "note"] } ?? [:])
        }
        let launcher = PrivilegedLauncher(helperURL: URL(fileURLWithPath: "/nonexistent")) { _, _, _, _ in }
        let before = box.tree()

        let report = await service(route: route).remove(items, mode: mode, administrator: launcher)

        #expect(calls.all == [["Example.app", "mode \(mode)", "cache gone true", "leftovers there true"]])
        #expect(report.outcomes.count == 4 && report.outcomes.first == .deleted(original: items[0].url))
        #expect(report.outcomes.dropFirst().allSatisfy { $0.isDone }, "\(report.outcomes)")
        #expect(report.notes == [items[0].url: "note"])
        let gone = ["root/Applications/Example.app", "\(caches)/com.example.app", "\(caches)/com.other", "home/Library/Preferences/com.example.app.plist"]
        #expect(Sandbox.difference(box.tree(), Sandbox.expected(before, without: gone)) == [])
    }

    /// GarageBand's shape (T-0074 review 1): a root-owned app and root-owned content that waits for it (0555 parents
    /// stand in for root), the content listed first. The content goes in the one helper request, after the app, in
    /// both modes; if the user cancels, neither moves.
    @Test(arguments: [DeletionMode.trash, .permanent], [false, true])
    func rootOwnedContentOfARootOwnedAppGoesInTheSameHelperRequest(mode: DeletionMode, cancelled: Bool) async throws {
        let bundle = try box.tmp.directory("root/Applications/GarageBand.app")
        try box.file("root/Applications/GarageBand.app/Contents/Info.plist")
        try box.file("root/Library/Application Support/GarageBand/Instrument Library/loops.caf")
        let parents = [box.url("root/Applications"), box.url("root/Library/Application Support")]
        #expect(parents.allSatisfy { chmod($0.path, 0o555) == 0 })
        defer { for parent in parents { chmod(parent.path, 0o755) } }
        let items = [item("root/Library/Application Support/GarageBand", requiresGone: bundle), item("root/Applications/GarageBand.app")]
        let calls = Calls()
        let box = box
        let route: TrashService.Route = { routed, _, _, _, _, _, _ in
            calls.record(routed.map(\.url.lastPathComponent))
            // What root does, item by item: one that waits for another goes only once that one is gone.
            let outcomes: [TrashOutcome] = routed.map { item in
                if cancelled { return .failed(item.url, message: "cancelled") }
                if let required = item.requiresGone, FileIdentity(url: required) != nil { return .failed(item.url, message: "still there") }
                let parent = item.url.deletingLastPathComponent().path
                chmod(parent, 0o755)
                try? FileManager.default.moveItem(at: item.url, to: box.trashFolder.appendingPathComponent(UUID().uuidString))
                chmod(parent, 0o555)
                return .deleted(original: item.url)
            }
            return (outcomes, [:])
        }
        let launcher = PrivilegedLauncher(helperURL: URL(fileURLWithPath: "/nonexistent")) { _, _, _, _ in }
        let before = box.tree()

        let report = await service(route: route).remove(items, mode: mode, administrator: launcher)

        #expect(calls.all == [["GarageBand.app", "GarageBand"]])
        if cancelled {
            #expect(report.outcomes == items.map { .failed($0.url, message: "cancelled") })
            #expect(Sandbox.difference(box.tree(), before) == [])
        } else {
            #expect(report.outcomes == items.map { .deleted(original: $0.url) })
            let gone = ["root/Library/Application Support/GarageBand", "root/Applications/GarageBand.app"]
            #expect(Sandbox.difference(box.tree(), Sandbox.expected(before, without: gone)) == [])
        }
    }

    /// The user cancels the administrator dialog for the root-owned bundle: every leftover that waits for it stays
    /// untouched, in both modes, and so does everything else of the app. Without a launcher, the same, with no call.
    @Test(arguments: [DeletionMode.trash, .permanent], [true, false])
    func aCancelledHelperLeavesEveryLeftoverUntouched(mode: DeletionMode, withLauncher: Bool) async throws {
        let bundle = try box.tmp.directory("root/Applications/Example.app")
        try box.file("root/Applications/Example.app/Contents/Info.plist")
        #expect(chmod(bundle.path, 0o555) == 0)
        try box.file("\(caches)/com.example.app/blob")
        try box.file("home/Library/Preferences/com.example.app.plist")
        let items = [
            item("root/Applications/Example.app"), item("\(caches)/com.example.app", requiresGone: bundle),
            item("home/Library/Preferences/com.example.app.plist", requiresGone: bundle),
        ]
        let calls = Calls()
        let route: TrashService.Route = { routed, _, launcher, _, _, _, _ in
            calls.record(routed.map(\.url.lastPathComponent))
            do {
                try await MainActor.run { try launcher.start(launcher.helperURL, URL(fileURLWithPath: "/nonexistent"), "", "") }
                return (routed.map { .deleted(original: $0.url) }, [:])
            } catch {
                return (routed.map { .failed($0.url, message: "\(error)") }, [:])
            }
        }
        let launcher = PrivilegedLauncher(helperURL: URL(fileURLWithPath: "/nonexistent")) { _, _, _, _ in throw PrivilegedError.cancelled }
        let before = box.tree()

        let report = await service(route: route).remove(items, mode: mode, administrator: withLauncher ? launcher : nil)

        #expect(Sandbox.difference(box.tree(), before) == [], "something of the app was removed")
        #expect(calls.all == (withLauncher ? [["Example.app"]] : []))
        #expect(report.outcomes.first == (withLauncher ? .failed(items[0].url, message: "cancelled") : .refused(items[0].url, .needsAdministrator)))
        let waiting = "Not removed, because Example.app is still there."
        #expect(Array(report.outcomes.dropFirst()) == items.dropFirst().map { .failed($0.url, message: waiting) })
    }
}

extension TrashOutcome {
    var deletedPath: String? {
        if case .deleted(let original) = self { original.path } else { nil }
    }

    /// Trashed or deleted.
    var isDone: Bool {
        switch self {
        case .trashed, .deleted: true
        case .refused, .failed: false
        }
    }
}

/// Thread-safe tallies for hooks and stand-ins.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    var all: [[String]] { lock.withLock { recorded } }

    func record(_ call: [String]) {
        lock.withLock { recorded.append(call) }
    }
}
