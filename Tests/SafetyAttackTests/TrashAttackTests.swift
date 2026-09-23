import Darwin
import Foundation
import MacontrolCore
import Safety
import Testing

/// Attacks on the one door every destructive action goes through. Each test builds a hostile tree in a sandbox,
/// calls the real `TrashService`, checks that exactly the intended items left, then undoes and checks that the
/// tree is back as it was, inode for inode.
@Suite struct TrashAttackTests {
    let box: Sandbox
    let caches = "home/Library/Caches"

    init() throws {
        box = try Sandbox()
    }

    func item(_ relative: String, keep: [URL] = []) -> TrashItem {
        TrashItem(url: box.url(relative), expectedIdentity: FileIdentity(url: box.url(relative)), keep: keep)
    }

    /// Trashes `items`, expects exactly `intended` (and what they hold) to have left, then undoes the batch
    /// and expects the tree to be as it was.
    @discardableResult
    func expectOnly(
        _ intended: [String], leaveWhenTrashing items: [TrashItem], sourceLocation: SourceLocation = #_sourceLocation
    ) async -> TrashReport {
        let before = box.tree()
        let service = box.service()
        let report = await service.moveToTrash(items)
        let stray = Sandbox.difference(box.tree(), Sandbox.expected(before, without: intended))
        #expect(stray == [], "moved something it should not have, or kept something it should have moved", sourceLocation: sourceLocation)
        let restored = await service.undo(batch: report.batch)
        #expect(restored.allSatisfy { $0.isRestored }, "\(restored)", sourceLocation: sourceLocation)
        #expect(Sandbox.difference(box.tree(), before) == [], "Undo did not put everything back", sourceLocation: sourceLocation)
        return report
    }

    /// No shell ever saw a name: a `touch PWNED-*` would have left its file in one of these folders.
    func expectNoCommandRan(sourceLocation: SourceLocation = #_sourceLocation) {
        let folders = [box.tmp.url, box.home, box.url(caches), URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            #expect(!names.contains { $0.hasPrefix("PWNED") }, "a command ran in \(folder.path)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Names

    /// `$(...)`, backticks, quotes, `&`, a leading dash, glob characters, newlines, a JSON line smuggled into a
    /// name, a Cyrillic lookalike and a decomposed accent: each moves as itself, nothing next to it moves, no
    /// command runs, the journal keeps one line per item, and Undo puts each back under its on-disk name.
    @Test func hostileNamesMoveAsThemselvesAndComeBack() async throws {
        for name in HostileNames.shell + [HostileNames.lookalike, HostileNames.decomposed, "Cache", "cafe", "rf", "touch"] {
            try box.file("\(caches)/\(name)/data")
        }
        // Asked for in composed form; the disk holds the decomposed one.
        let chosen = HostileNames.shell + [HostileNames.lookalike, "caf\u{00E9}"]

        let report = await expectOnly(chosen.map { "\(caches)/\($0)" }, leaveWhenTrashing: chosen.map { item("\(caches)/\($0)") })

        #expect(report.outcomes.count == chosen.count && report.outcomes.allSatisfy { $0.isTrashed })
        let history = await box.service().history()
        #expect(history.count == chosen.count, "a name added or hid a journal line")
        #expect(history.allSatisfy { $0.batch == report.batch && $0.originalPath.hasPrefix(box.url(caches).path + "/") })
        expectNoCommandRan()
    }

    // MARK: Protected places inside the fake home

    /// Home itself, its parent, Library, Documents, `.ssh`, Keychains, the Trash and iCloud Drive, reached
    /// directly, through `..`, through the Data volume's spelling and through links that point at them.
    /// None reaches the backend; the one ordinary cache in the same batch still goes.
    @Test func protectedPlacesNeverMove() async throws {
        try box.file("home/.ssh/id_ed25519")
        try box.file("home/Documents/thesis.docx")
        try box.file("home/Library/Keychains/login.keychain-db")
        try box.file("home/.Trash/old.zip")
        try box.file("home/Library/Mobile Documents/com~apple~CloudDocs/notes.txt")
        try box.file("\(caches)/com.example.ordinary/blob")
        try FileManager.default.createSymbolicLink(atPath: box.url("\(caches)/sneaky").path, withDestinationPath: "../../.ssh")
        try FileManager.default.createSymbolicLink(at: box.url("\(caches)/docs"), withDestinationURL: box.url("home/Documents"))
        let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data" + box.url("home/Documents").path)

        let attacks = [
            "home", "home/Library", "home/Library/Caches", "home/Documents", "home/.ssh", "home/.ssh/id_ed25519",
            "home/Library/Keychains", "home/Library/Keychains/login.keychain-db", "home/.Trash", "home/.Trash/old.zip",
            "home/Library/Mobile Documents", "home/Library/Mobile Documents/com~apple~CloudDocs",
            "home/Library/Mobile Documents/com~apple~CloudDocs/notes.txt",
            "\(caches)/../../Documents", "\(caches)/sneaky/.", "\(caches)/sneaky/id_ed25519", "\(caches)/docs/.", "\(caches)/..",
        ].map { TrashItem(url: box.url($0), expectedIdentity: nil) }
        let items = attacks + [
            TrashItem(url: URL(fileURLWithPath: box.tmp.url.path), expectedIdentity: nil),
            TrashItem(url: dataVolume, expectedIdentity: nil),
            item("\(caches)/com.example.ordinary"),
        ]

        let report = await expectOnly(["\(caches)/com.example.ordinary"], leaveWhenTrashing: items)

        let refused = report.outcomes.filter { $0.refusal != nil }
        #expect(refused.count == items.count - 1, "\(report.outcomes.filter { $0.refusal == nil })")
        #expect(box.backendCalls.map(\.lastPathComponent) == ["com.example.ordinary"])
    }

    // MARK: Links

    /// A selected symlink is the link: the folder, file or key it points at stays, even when it is protected.
    @Test func aSelectedLinkMovesTheLinkNotItsTarget() async throws {
        try box.file("home/.ssh/id_ed25519")
        try box.file("home/Documents/thesis.docx", size: 1 << 20)
        let links = ["to-docs": box.url("home/Documents").path, "to-ssh": "../../.ssh", "to-file": box.url("home/Documents/thesis.docx").path, "dangling": "/nonexistent-macontrol"]
        for (name, destination) in links {
            try FileManager.default.createSymbolicLink(atPath: box.url("\(caches)/\(name)").path, withDestinationPath: destination)
        }

        let chosen = links.keys.sorted().map { "\(caches)/\($0)" }
        let report = await expectOnly(chosen, leaveWhenTrashing: chosen.map { item($0) })

        #expect(report.outcomes.allSatisfy { $0.isTrashed })
    }

    /// A hard link is one more name for the same data: trashing the cache that holds it leaves the user's copy,
    /// the key's other name and their bytes exactly where they were.
    @Test func hardLinksOutsideTheSelectionKeepTheirData() async throws {
        let thesis = try box.file("home/Documents/big.bin", size: 1 << 20)
        try Data(repeating: 0x5A, count: 1 << 20).write(to: thesis)
        try box.file("home/.ssh/id_ed25519")
        try box.tmp.hardLink("\(caches)/com.example.links/big.bin", to: "home/Documents/big.bin")
        try box.tmp.hardLink("\(caches)/com.example.links/key", to: "home/.ssh/id_ed25519")

        await expectOnly(["\(caches)/com.example.links"], leaveWhenTrashing: [item("\(caches)/com.example.links")])

        #expect(try Data(contentsOf: thesis) == Data(repeating: 0x5A, count: 1 << 20))
    }

    // MARK: Swaps between scan and delete (TOCTOU)

    /// After the scan, a selected folder becomes a link to Documents, and a selected file's folder becomes a link
    /// to a project holding a file of the same name. Both are refused before the backend is called.
    @Test func aSwapAfterTheScanIsRefused() async throws {
        try box.file("\(caches)/com.example.swapped/blob")
        try box.file("\(caches)/com.example.parent/blob")
        try box.file("home/Documents/thesis.docx")
        try box.file("home/Documents/proj/blob")
        let items = [item("\(caches)/com.example.swapped"), item("\(caches)/com.example.parent/blob")]
        try box.swapForSymlink("\(caches)/com.example.swapped", to: box.url("home/Documents"))
        try box.swapForSymlink("\(caches)/com.example.parent", to: box.url("home/Documents/proj"))

        let report = await expectOnly([], leaveWhenTrashing: items)

        #expect(report.outcomes.map(\.refusal) == [.identityChanged, .identityChanged])
        #expect(box.backendCalls.isEmpty)
    }

    /// The swap lands while the batch runs: the second item's folder turns into a link as the first one moves.
    @Test func aSwapDuringTheBatchIsRefused() async throws {
        try box.file("\(caches)/com.example.first/blob")
        try box.file("\(caches)/com.example.second/data.bin")
        try box.file("home/Documents/proj/data.bin")
        let items = [item("\(caches)/com.example.first"), item("\(caches)/com.example.second/data.bin")]
        let box = self.box
        box.beforeEachMove { url in
            if url.lastPathComponent == "com.example.first" {
                try? box.swapForSymlink("home/Library/Caches/com.example.second", to: box.url("home/Documents/proj"))
            }
        }
        let documents = box.tree().filter { $0.key.hasPrefix("home/Documents") }

        let report = await box.service().moveToTrash(items)

        #expect(report.outcomes.first?.isTrashed == true)
        #expect(report.outcomes.last?.refusal == .identityChanged)
        #expect(box.tree().filter { $0.key.hasPrefix("home/Documents") } == documents)
    }

    /// The swap lands after the last check, inside the move itself. A path-based move (the sandbox's rename, like
    /// `FileManager.trashItem`) follows the new link, so the object that leaves is not the one that was checked.
    /// Safety must notice that what reached the Trash is not what it checked, and put it back.
    @Test func aSwapInsideTheMoveMustNotTrashTheLinkedFile() async throws {
        try box.file("\(caches)/com.example.window/data.bin")
        try box.file("home/Documents/proj/data.bin")
        let box = self.box
        box.beforeEachMove { url in
            if url.lastPathComponent == "data.bin" {
                try? box.swapForSymlink("home/Library/Caches/com.example.window", to: box.url("home/Documents/proj"))
            }
        }
        let documents = box.tree().filter { $0.key.hasPrefix("home/Documents") }

        let report = await box.service().moveToTrash([item("\(caches)/com.example.window/data.bin")])

        withKnownIssue("T-0053: the moved object is not checked against the identity after the move") {
            #expect(box.tree().filter { $0.key.hasPrefix("home/Documents") } == documents, "Documents/proj/data.bin went to the Trash")
            #expect(report.outcomes.first?.isTrashed != true)
        }
    }

    /// A hard link keeps the identity through a folder swap: `com.example.shared/blob` and `Documents/proj/blob`
    /// are one inode, and after the swap the selected path reaches the Documents name. Identity alone passes it.
    @Test func aSwapOntoAHardLinkMustNotTrashTheDocumentsName() async throws {
        try box.file("home/Documents/proj/blob")
        try box.tmp.hardLink("\(caches)/com.example.shared/blob", to: "home/Documents/proj/blob")
        let selected = item("\(caches)/com.example.shared/blob")
        try box.swapForSymlink("\(caches)/com.example.shared", to: box.url("home/Documents/proj"))
        let before = box.tree()

        let report = await box.service().moveToTrash([selected])

        withKnownIssue("T-0054: a folder in the path that became a link is not noticed when the leaf keeps its identity") {
            #expect(Sandbox.difference(box.tree(), before) == [], "Documents/proj/blob went to the Trash")
            #expect(report.outcomes.first?.refusal != nil)
        }
    }

    // MARK: Locked items

    /// A locked file, a locked folder and a file in a locked folder are refused, with their flags as the user set them.
    @Test func lockedItemsAreRefusedAndStayLocked() async throws {
        try box.file("\(caches)/com.example.lockedfile/blob")
        try box.file("\(caches)/com.example.lockedfolder/blob")
        try box.file("\(caches)/com.example.inlocked/blob")
        for path in ["com.example.lockedfile/blob", "com.example.lockedfolder", "com.example.inlocked"] {
            #expect(chflags(box.url("\(caches)/\(path)").path, UInt32(UF_IMMUTABLE)) == 0)
        }
        let items = [item("\(caches)/com.example.lockedfile/blob"), item("\(caches)/com.example.lockedfolder"), item("\(caches)/com.example.inlocked/blob")]

        let report = await expectOnly([], leaveWhenTrashing: items)

        #expect(report.outcomes.map(\.refusal) == [.locked, .locked, .locked])
    }

    /// The user locked one file inside a folder that is selected as a whole. The lock says "keep this"; it must
    /// not ride into the Trash with its folder, where Empty Trash is one click from it.
    @Test func aLockedFileInsideASelectedFolderStays() async throws {
        try box.file("\(caches)/com.example.holder/junk.bin")
        try box.file("\(caches)/com.example.holder/keepsake.txt")
        #expect(chflags(box.url("\(caches)/com.example.holder/keepsake.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        let before = box.tree()

        _ = await box.service().moveToTrash([item("\(caches)/com.example.holder")])

        withKnownIssue("T-0055: only the item and its folder are checked for the Locked flag, not what the item holds") {
            #expect(before["\(caches)/com.example.holder/keepsake.txt"] == box.tree()["\(caches)/com.example.holder/keepsake.txt"])
        }
    }

    // MARK: Unchecked children (keep)

    /// The user unchecks `src` (reached through a link to the project) and `NOTES.md` (spelled in other case)
    /// inside the checked project: everything else goes piece by piece, the two stay, and Undo rebuilds the folder.
    @Test func uncheckedChildrenSurviveHoweverTheyAreSpelled() async throws {
        let project = "\(caches)/com.example.project"
        try box.file("\(project)/src/main.swift")
        try box.file("\(project)/build/out.o", size: 1 << 16)
        try box.file("\(project)/NOTES.md")
        try box.file("\(project)/.git/HEAD")
        try FileManager.default.createSymbolicLink(at: box.url("\(caches)/alias"), withDestinationURL: box.url(project))
        let keep = [box.url("\(caches)/alias/src"), box.url("\(caches)/COM.EXAMPLE.PROJECT/notes.MD")]

        let report = await expectOnly(["\(project)/build", "\(project)/.git"], leaveWhenTrashing: [item(project, keep: keep)])

        #expect(report.outcomes.filter(\.isTrashed).count == 2)
    }

    /// A kept path nested past PATH_MAX cannot be resolved, so nothing in the batch may move (fail closed).
    @Test func aKeptPathPastPathMaxStopsTheWholeBatch() async throws {
        let chain = try box.deepChain("\(caches)/com.example.deepkeep/tree")
        try box.file("\(caches)/com.example.deepkeep/junk.bin")
        try box.file("\(caches)/com.example.other/junk.bin")
        let keep = box.url(chain.leaf)
        #expect(keep.path.utf8.count > Int(MAXPATHLEN))

        let report = await expectOnly([], leaveWhenTrashing: [item("\(caches)/com.example.deepkeep", keep: [keep]), item("\(caches)/com.example.other")])

        #expect(report.outcomes.allSatisfy { if case .failed = $0 { true } else { false } })
        #expect(box.backendCalls.isEmpty)
    }

    // MARK: Depth

    /// A folder holding a chain deeper than PATH_MAX moves as one item and comes back whole; an item that is
    /// itself past PATH_MAX is refused without reaching the backend.
    @Test func deepTreesMoveWholeAndDeepItemsAreRefused() async throws {
        let chain = try box.deepChain("\(caches)/com.example.deep")
        #expect(box.url(chain.leaf).path.utf8.count > Int(MAXPATHLEN))
        #expect(box.tree()[chain.leaf] != nil)

        await expectOnly(["\(caches)/com.example.deep"], leaveWhenTrashing: [item("\(caches)/com.example.deep")])
        let report = await box.service().moveToTrash([TrashItem(url: box.url(chain.leaf), expectedIdentity: nil)])

        #expect(report.outcomes.map(\.refusal) == [.needsAdministrator])
        #expect(box.backendCalls.count == 1)
    }

    // MARK: The journal

    /// The journal's path is a link to the user's `authorized_keys`: nothing moves without a journal of its own,
    /// and the linked file is not written.
    @Test func aLinkedJournalStopsTheBatch() async throws {
        let keys = try box.file("home/.ssh/authorized_keys", size: 100)
        try box.tmp.directory("state")
        try FileManager.default.createSymbolicLink(at: box.journal, withDestinationURL: keys)
        try box.file("\(caches)/com.example.victim/blob")

        let report = await expectOnly([], leaveWhenTrashing: [item("\(caches)/com.example.victim")])

        #expect(report.outcomes.allSatisfy { if case .failed = $0 { true } else { false } })
        #expect(try Data(contentsOf: keys) == Data(count: 100))
    }
}
