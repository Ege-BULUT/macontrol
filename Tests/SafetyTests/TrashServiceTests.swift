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
}
