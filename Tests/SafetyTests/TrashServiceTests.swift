import Darwin
import Foundation
import MacontrolCore
import Safety
import Testing
import TestSupport

@Suite struct TrashServiceTests {
    @Test func protectedItemsNeverReachTheBackend() async throws {
        let fixture = try TrashFixture()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let items = ["/", home.path, home.path + "/Library", "/System/Volumes/Data" + home.path, home.path + "/.ssh/id_ed25519"]
            .map { TrashItem(url: URL(fileURLWithPath: $0), expectedIdentity: nil) }

        let report = await fixture.service(home: home).moveToTrash(items)

        #expect(report.outcomes.count == items.count)
        #expect(report.outcomes.allSatisfy { $0.refusal?.isProtectedLocation == true }, "\(report.outcomes)")
        #expect(fixture.backendCalls.isEmpty)
    }

    // F-0036, F-0064: the backend gets the item itself under its own name, never a hidden staging copy.
    @Test func trashesUnderTheItemsOwnNameAndJournalsIt() async throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("home/Library/Caches/com.example.App/cache.db", size: 4096)
        let folder = file.deletingLastPathComponent()
        let identity = try #require(FileIdentity(url: folder))

        let report = await fixture.service().moveToTrash([TrashItem(url: folder, expectedIdentity: identity, allocated: 4096)])

        let destination = fixture.trash.appendingPathComponent("com.example.App")
        #expect(report.outcomes.map(\.paths) == [[folder.path, destination.path]])
        #expect(fixture.backendCalls == [folder])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("cache.db").path))

        let history = await fixture.service().history()
        #expect(history == [JournalEntry(
            batch: report.batch, date: try #require(history.first?.date), originalPath: folder.path,
            trashedPath: destination.path, identity: identity, allocated: 4096, restored: false
        )])
    }

    @Test func refusesAnItemWhoseIdentityChanged() async throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("home/Downloads/setup.dmg", size: 10)
        let scanned = try #require(FileIdentity(url: file))
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("kept.dmg"))
        try fixture.tmp.file("home/Downloads/setup.dmg", size: 20)

        let report = await fixture.service().moveToTrash([TrashItem(url: file, expectedIdentity: scanned)])

        #expect(report.outcomes == [.refused(file, .identityChanged)])
        #expect(fixture.backendCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // F-0024, F-0070: a locked item is refused and its flag is left exactly as the user set it.
    @Test func refusesALockedFileAndLeavesItLocked() async throws {
        let fixture = try TrashFixture()
        let locked = try fixture.tmp.file("home/Movies/final.mov", size: 10)
        let other = try fixture.tmp.file("home/Movies/draft.mov", size: 10)
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.path, 0) }

        let report = await fixture.service().moveToTrash([
            TrashItem(url: locked, expectedIdentity: nil), TrashItem(url: other, expectedIdentity: nil),
        ])

        #expect(report.outcomes.first == .refused(locked, .locked))
        #expect(report.outcomes.last?.trashedTo != nil, "a refusal must not stop the batch")
        var info = stat()
        #expect(lstat(locked.path, &info) == 0)
        #expect(info.st_flags & UInt32(UF_IMMUTABLE) != 0)
    }

    @Test func cloudItemsNeedConfirmationBeforeTheyMove() async throws {
        let fixture = try TrashFixture()
        let doc = try fixture.tmp.file("home/Library/Mobile Documents/com~apple~CloudDocs/Notes.txt", size: 10)
        let item = TrashItem(url: doc, expectedIdentity: nil)

        let refused = await fixture.service().moveToTrash([item])
        #expect(refused.outcomes == [.refused(doc, .needsCloudConfirmation)])
        #expect(fixture.backendCalls.isEmpty)

        let confirmed = await fixture.service().moveToTrash([item], cloudConfirmed: true)
        #expect(confirmed.outcomes.first?.trashedTo != nil)
    }

    // F-0026: unchecked descendants stay; everything around them goes.
    @Test func keepsUncheckedDescendants() async throws {
        let fixture = try TrashFixture()
        let root = try fixture.tmp.directory("home/Projects/old")
        try fixture.tmp.file("home/Projects/old/build.log", size: 10)
        try fixture.tmp.file("home/Projects/old/src/main.c", size: 10)
        let kept = try fixture.tmp.file("home/Projects/old/src/notes.md", size: 10)
        try fixture.tmp.file("home/Projects/old/src/lib/util.c", size: 10)

        let report = await fixture.service().moveToTrash([TrashItem(url: root, expectedIdentity: FileIdentity(url: root), keep: [kept])])

        #expect(report.outcomes.count == 3)
        #expect(report.outcomes.allSatisfy { $0.trashedTo != nil })
        #expect(FileManager.default.fileExists(atPath: kept.path))
        let left = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["src", "src/notes.md"])
    }

    // F-0026, fail closed: a kept path that cannot be resolved stops the whole item.
    @Test func keepSurvivesWhenItsFolderCannotBeOpened() async throws {
        let fixture = try TrashFixture()
        let root = try fixture.tmp.directory("home/Projects/old")
        try fixture.tmp.file("home/Projects/old/build.log", size: 10)
        let kept = try fixture.tmp.file("home/Projects/old/private/keep-me.txt", size: 10)
        let folder = kept.deletingLastPathComponent()
        #expect(chmod(folder.path, 0o300) == 0) // search but no read: open(O_RDONLY) fails
        defer { chmod(folder.path, 0o755) }

        let report = await fixture.service().moveToTrash([TrashItem(url: root, expectedIdentity: FileIdentity(url: root), keep: [kept])])

        guard case .failed(root, _) = report.outcomes.first else { Issue.record("\(report.outcomes)"); return }
        #expect(report.outcomes.count == 1)
        #expect(fixture.backendCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    // F-0026: APFS ignores case, so `OLD` is `old` and its kept file stays while the rest goes.
    @Test func keepSurvivesWhenTheItemIsSpelledInAnotherCase() async throws {
        let fixture = try TrashFixture()
        let log = try fixture.tmp.file("home/Projects/old/build.log", size: 10)
        let kept = try fixture.tmp.file("home/Projects/old/src/notes.md", size: 10)
        let spelled = fixture.home.appendingPathComponent("Projects/OLD")

        let report = await fixture.service().moveToTrash([TrashItem(url: spelled, expectedIdentity: nil, keep: [kept])])

        #expect(FileManager.default.fileExists(atPath: kept.path), "backend got \(fixture.backendCalls.map(\.path))")
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(report.outcomes.map(\.paths) == [[spelled.path + "/build.log", fixture.trash.path + "/build.log"]])
    }

    // A folder whose every child is kept moves nothing, and still says so under its own URL.
    @Test func anItemWithNothingLeftToMoveReportsItself() async throws {
        let fixture = try TrashFixture()
        let root = try fixture.tmp.directory("home/Projects/old")
        let kept = try fixture.tmp.file("home/Projects/old/notes.md", size: 10)

        let report = await fixture.service().moveToTrash([
            TrashItem(url: root, expectedIdentity: nil, keep: [kept]),
            TrashItem(url: kept, expectedIdentity: nil, keep: [kept]),
        ])

        guard case .failed(root, _) = report.outcomes.first, case .failed(kept, _) = report.outcomes.last else {
            Issue.record("\(report.outcomes)")
            return
        }
        #expect(report.outcomes.count == 2)
        #expect(fixture.backendCalls.isEmpty)
    }

    // F-0026: a deselection wins over every other selected item, from below and from above.
    @Test func keepHoldsAgainstASelectedDescendant() async throws {
        let fixture = try TrashFixture()
        let root = try fixture.tmp.directory("home/Projects/old")
        let log = try fixture.tmp.file("home/Projects/old/build.log", size: 10)
        let main = try fixture.tmp.file("home/Projects/old/src/main.c", size: 10)
        let kept = try fixture.tmp.file("home/Projects/old/src/notes.md", size: 10)

        let report = await fixture.service().moveToTrash([
            TrashItem(url: root, expectedIdentity: nil, keep: [kept]),
            TrashItem(url: kept.deletingLastPathComponent(), expectedIdentity: nil),
        ])

        #expect(FileManager.default.fileExists(atPath: kept.path), "\(report.outcomes)")
        #expect(![log, main].contains { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func keepHoldsAgainstASelectedAncestor() async throws {
        let fixture = try TrashFixture()
        let root = try fixture.tmp.directory("home/Projects/old")
        let log = try fixture.tmp.file("home/Projects/old/build.log", size: 10)
        let kept = try fixture.tmp.file("home/Projects/old/src/notes.md", size: 10)

        let report = await fixture.service().moveToTrash([
            TrashItem(url: root, expectedIdentity: nil),
            TrashItem(url: kept.deletingLastPathComponent(), expectedIdentity: nil, keep: [kept]),
            TrashItem(url: kept, expectedIdentity: nil),
        ])

        #expect(FileManager.default.fileExists(atPath: kept.path), "\(report.outcomes)")
        #expect(!FileManager.default.fileExists(atPath: log.path))
        guard case .failed(kept, _) = report.outcomes.last else { Issue.record("\(report.outcomes)"); return }
    }

    // On a case-sensitive volume `Cache` and `cache` are two folders: trashing one says nothing about the other.
    // Env-gated: attaches a small disk image inside the test's own folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_DISK_IMAGE_TESTS"] == "1"))
    func onACaseSensitiveVolumeATwinFolderIsNotReportedAsTrashed() async throws {
        let fixture = try TrashFixture()
        let volume = try fixture.attachDiskImage("Case-sensitive APFS", at: "volume")
        let upper = volume.appendingPathComponent("Cache")
        let other = volume.appendingPathComponent("cache/b.bin")
        try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data(count: 10).write(to: other)

        let report = await fixture.service().moveToTrash([
            TrashItem(url: upper, expectedIdentity: nil), TrashItem(url: other, expectedIdentity: nil),
        ])

        let expected = [fixture.trash.path + "/Cache", fixture.trash.path + "/b.bin"]
        #expect(report.outcomes.map { $0.trashedTo?.path } == expected, "\(report.outcomes)")
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func aDuplicateSelectionIsReportedAsTrashed() async throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("home/Library/Caches/dup.bin", size: 10)
        let shouted = fixture.home.appendingPathComponent("Library/Caches/DUP.BIN")

        let report = await fixture.service().moveToTrash([file, file, shouted].map { TrashItem(url: $0, expectedIdentity: nil) })

        let destination = fixture.trash.appendingPathComponent("dup.bin")
        #expect(report.outcomes.map(\.trashedTo) == [destination, destination, destination], "\(report.outcomes)")
        #expect(fixture.backendCalls == [file])
    }

    // F-0050: a folder and something selected inside it are trashed once, as the folder.
    @Test func trashesAnAncestorAndItsSelectedDescendantOnce() async throws {
        let fixture = try TrashFixture()
        let inner = try fixture.tmp.file("home/Library/Caches/big/inner/blob.bin", size: 10)
        let outer = fixture.home.appendingPathComponent("Library/Caches/big")

        let report = await fixture.service().moveToTrash([
            TrashItem(url: inner, expectedIdentity: nil), TrashItem(url: outer, expectedIdentity: nil),
        ])

        let destination = fixture.trash.appendingPathComponent("big")
        #expect(fixture.backendCalls == [outer])
        #expect(report.outcomes.map(\.paths) == [
            [inner.path, destination.path + "/inner/blob.bin"],
            [outer.path, destination.path],
        ])
        #expect(await fixture.service().history().count == 1)
    }

    @Test func journalIsPrivateToTheUser() async throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("home/Library/Logs/app.log", size: 10)

        _ = await fixture.service().moveToTrash([TrashItem(url: file, expectedIdentity: nil)])

        var info = stat()
        #expect(stat(fixture.journal.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(fixture.journal.deletingLastPathComponent().path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    // Trashing the journal, or a folder holding it, would take Undo away from every earlier batch.
    @Test func theJournalAndTheFoldersHoldingItAreRefused() async throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("home/Library/Caches/a.tmp", size: 10)
        let service = fixture.service()
        let first = await service.moveToTrash([TrashItem(url: file, expectedIdentity: nil)])
        let folder = fixture.journal.deletingLastPathComponent()

        let second = await service.moveToTrash(
            [fixture.journal, folder, folder.deletingLastPathComponent()].map { TrashItem(url: $0, expectedIdentity: nil) }
        )

        #expect(second.outcomes.count == 3)
        #expect(second.outcomes.allSatisfy { $0.refusal?.isProtectedLocation == true }, "\(second.outcomes)")
        #expect(await service.undo(batch: first.batch) == [.restored(file)])
        // The pre-check the UI runs agrees for the real journal.
        let realFolder = TrashService.defaultJournalURL.deletingLastPathComponent()
        #expect(ProtectedPaths.refusal(for: realFolder)?.isProtectedLocation == true)
    }

    @Test func undoPutsTheItemBackUnderItsOnDiskName() async throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("home/Downloads/report.pdf", size: 10)
        let shouted = fixture.home.appendingPathComponent("Downloads/REPORT.PDF")
        let service = fixture.service()

        let report = await service.moveToTrash([TrashItem(url: shouted, expectedIdentity: nil)])
        #expect(await service.history().map(\.originalPath) == [file.path])
        #expect(await service.undo(batch: report.batch) == [.restored(file)])

        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["report.pdf"])
    }

    // A link swapped in for a folder on the way back cannot send the item somewhere else.
    @Test func undoDoesNotFollowALinkThatReplacedAFolder() async throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("home/Projects/app/notes.txt", size: 10)
        let elsewhere = try fixture.tmp.directory("elsewhere")
        let service = fixture.service()
        let report = await service.moveToTrash([TrashItem(url: file, expectedIdentity: nil)])
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try fixture.tmp.symlink("home/Projects/app", to: elsewhere.path)

        let outcomes = await service.undo(batch: report.batch)

        guard case .failed(file, _) = outcomes.first else { Issue.record("\(outcomes)"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("notes.txt").path))
    }

    // The trashed item may itself be a link: only links on the way back are refused.
    @Test func undoPutsBackATrashedLink() async throws {
        let fixture = try TrashFixture()
        let link = try fixture.tmp.symlink("home/Downloads/latest", to: "nowhere")
        let service = fixture.service()

        let report = await service.moveToTrash([TrashItem(url: link, expectedIdentity: nil)])

        #expect(await service.undo(batch: report.batch) == [.restored(link)])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "nowhere")
    }

    @Test func undoRestoresTheSameBytesAndIdentity() async throws {
        let fixture = try TrashFixture()
        let file = fixture.home.appendingPathComponent("Documents/letter.txt")
        try fixture.tmp.directory("home/Documents")
        let bytes = Data("Dear macontrol,\n".utf8)
        try bytes.write(to: file)
        let identity = FileIdentity(url: file)
        let service = fixture.service()

        let report = await service.moveToTrash([TrashItem(url: file, expectedIdentity: identity)])
        #expect(!FileManager.default.fileExists(atPath: file.path))

        #expect(await service.undo(batch: report.batch) == [.restored(file)])
        #expect(try Data(contentsOf: file) == bytes)
        #expect(FileIdentity(url: file) == identity)
        #expect(await service.history().first?.restored == true)
        #expect(await service.undo(batch: report.batch).isEmpty, "a restored batch has nothing left to undo")
    }

    @Test func undoNeverReplacesWhatTookTheOriginalPath() async throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("home/Desktop/todo.txt", size: 10)
        let service = fixture.service()
        let report = await service.moveToTrash([TrashItem(url: file, expectedIdentity: nil)])
        let newcomer = Data("new".utf8)
        try newcomer.write(to: file)

        let outcomes = await service.undo(batch: report.batch)

        guard case .failed(let url, _) = outcomes.first else { Issue.record("expected a failure, got \(outcomes)"); return }
        #expect(url == file)
        #expect(try Data(contentsOf: file) == newcomer)
        #expect(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("todo.txt").path))
        #expect(await service.history().first?.restored == false)
    }

    // F-0036: a crash can tear the last line; everything before it still undoes.
    @Test func aTornJournalLineIsSkipped() async throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("home/Library/Caches/x.tmp", size: 10)
        let service = fixture.service()
        _ = await service.moveToTrash([TrashItem(url: file, expectedIdentity: nil)])
        let handle = try FileHandle(forWritingTo: fixture.journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"batch\":\"trunc".utf8))
        try handle.close()

        #expect(await service.history().count == 1)
        let next = try fixture.tmp.file("home/Library/Caches/y.tmp", size: 10)
        _ = await service.moveToTrash([TrashItem(url: next, expectedIdentity: nil)])
        let history = await service.history()
        let journal = String(decoding: try Data(contentsOf: fixture.journal), as: UTF8.self)
        #expect(history.map(\.originalPath) == [next.path, file.path], "\(journal)")
    }

    /// v1 lines have no `asAdministrator` and always a `trashedPath`; they must keep decoding (T-0072).
    /// A line without `trashedPath` is a permanent deletion, and Undo never touches it.
    @Test func v1JournalLinesDecodeAndPermanentLinesHaveNoUndo() async throws {
        let fixture = try TrashFixture()
        let batch = UUID()
        let (a, b, gone) = (fixture.home.appendingPathComponent("a"), fixture.home.appendingPathComponent("b"), fixture.trash.appendingPathComponent("a"))
        let common = #""batch":"\#(batch.uuidString)","date":"2026-01-01T00:00:00Z","identity":{"device":1,"inode":2},"restored":false"#
        let lines = [
            #"{"allocated":4096,\#(common),"originalPath":"\#(a.path)","trashedPath":"\#(gone.path)"}"#,
            #"{"allocated":0,\#(common),"originalPath":"\#(b.path)"}"#,
        ]
        try FileManager.default.createDirectory(at: fixture.journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fixture.journal)

        let history = await fixture.service().history()
        #expect(history.map(\.originalPath) == [b.path, a.path])
        #expect(history.map(\.isPermanent) == [true, false])
        #expect(history.allSatisfy { !$0.asAdministrator && $0.restorePoint == nil })
        // Only the trashed line is tried; it is no longer in the fixture Trash.
        #expect(await fixture.service().undo(batch: batch) == [.failed(a, message: "It is no longer in the Trash.")])
    }
}
