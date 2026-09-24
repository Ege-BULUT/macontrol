import Darwin
import Foundation
import MacontrolCore
@testable import Safety
import Testing
import TestSupport

/// Hardcore mode's delete (DESIGN-debloat section 2): a file goes with one unlinkat in place, a folder is moved to the
/// fixture Trash first and erased there. Every remover here stops the test process before it could touch anything
/// outside its fixture (`TrashFixture.guardedService(hook:route:)`).
@Suite struct PermanentDeleteTests {
    let fixture: TrashFixture

    init() throws {
        fixture = try TrashFixture()
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    func trashNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).sorted()
    }

    // MARK: The two sinks

    @Test func aFolderIsErasedAfterItsTrashMoveAndJournaledWithoutATrashPath() async throws {
        try fixture.tmp.file("home/Library/Caches/com.example.App/a/b/cache.db", size: 4096)
        let folder = fixture.home.appendingPathComponent("Library/Caches/com.example.App")
        let identity = try #require(FileIdentity(url: folder))

        let report = await fixture.guardedService().remove(
            [TrashItem(url: folder, expectedIdentity: identity, allocated: 4096)], mode: .permanent, restorePoint: "com.apple.TimeMachine.x.local"
        )

        #expect(report.outcomes == [.deleted(original: folder)])
        #expect(fixture.backendCalls == [folder], "a folder goes through the Trash move first")
        #expect(!exists(folder))
        #expect(try trashNames() == [], "the erase empties what reached the Trash")
        let history = await fixture.service().history()
        #expect(history == [JournalEntry(
            batch: report.batch, date: try #require(history.first?.date), originalPath: folder.path, trashedPath: nil,
            identity: identity, allocated: 4096, restored: false, restorePoint: "com.apple.TimeMachine.x.local"
        )])
        #expect(await fixture.service().undo(batch: report.batch).isEmpty, "a permanent deletion has no Undo")
    }

    @Test func aFileAndALinkAreDeletedInPlaceWithoutTheTrash() async throws {
        let file = try fixture.tmp.file("home/Downloads/setup.dmg", size: 10)
        let target = try fixture.tmp.file("home/Documents/thesis.docx", size: 10)
        let link = try fixture.tmp.symlink("home/Downloads/thesis-link", to: target.path)

        let report = await fixture.guardedService().remove(
            [file, link].map { TrashItem(url: $0, expectedIdentity: FileIdentity(url: $0)) }, mode: .permanent
        )

        #expect(report.outcomes == [.deleted(original: file), .deleted(original: link)])
        #expect(fixture.backendCalls.isEmpty)
        #expect(!exists(file) && !exists(link))
        #expect(exists(target), "a link goes as the link")
        #expect(await fixture.service().history().map(\.isPermanent) == [true, true])
    }

    // MARK: Links

    /// A link at the leaf to a file outside, and one mid-tree to a folder outside: both go as links, and what they
    /// point to stays byte for byte.
    @Test func linksAtTheLeafAndMidTreeAreRemovedNotFollowed() async throws {
        let canary = try fixture.tmp.file("outside/canary.txt", size: 100)
        let canaryFolder = try fixture.tmp.directory("outside/folder")
        try fixture.tmp.file("outside/folder/inner.txt", size: 100)
        let folder = try fixture.tmp.directory("home/Library/Caches/links")
        try fixture.tmp.file("home/Library/Caches/links/a/b/data.bin", size: 10)
        try fixture.tmp.symlink("home/Library/Caches/links/a/b/leaf", to: canary.path)
        try fixture.tmp.symlink("home/Library/Caches/links/a/mid", to: canaryFolder.path)
        try fixture.tmp.symlink("home/Library/Caches/links/relative", to: "../../../../outside/folder")

        let report = await fixture.guardedService().remove([TrashItem(url: folder, expectedIdentity: FileIdentity(url: folder))], mode: .permanent)

        #expect(report.outcomes == [.deleted(original: folder)])
        #expect(try Data(contentsOf: canary) == Data(count: 100))
        #expect(try FileManager.default.contentsOfDirectory(atPath: canaryFolder.path) == ["inner.txt"])
        #expect(try trashNames() == [])
    }

    /// Between the walk's look at `a/b` and its open, `a/b` becomes a link to a folder outside. The open refuses to
    /// follow it, the link goes as a link, and the folder it points to keeps every file.
    @Test func aFolderSwappedForALinkMidWalkIsRemovedAsTheLink() async throws {
        let canary = try fixture.tmp.directory("outside/canary")
        try fixture.tmp.file("outside/canary/keep.txt", size: 100)
        let folder = try fixture.tmp.directory("home/Library/Caches/swap")
        try fixture.tmp.file("home/Library/Caches/swap/a/b/data.bin", size: 10)
        let parked = fixture.tmp.url.appendingPathComponent("parked")
        let service = fixture.guardedService(hook: { item, relative in
            guard relative == "a/b" else { return }
            let b = URL(fileURLWithPath: item).appendingPathComponent("a/b")
            try? FileManager.default.moveItem(at: b, to: parked)
            try? FileManager.default.createSymbolicLink(at: b, withDestinationURL: canary)
        })

        let report = await service.remove([TrashItem(url: folder, expectedIdentity: FileIdentity(url: folder))], mode: .permanent)

        #expect(report.outcomes == [.deleted(original: folder)], "the swapped-in link is removed as a link")
        #expect(try FileManager.default.contentsOfDirectory(atPath: canary.path) == ["keep.txt"])
        #expect(exists(parked.appendingPathComponent("data.bin")), "the folder moved away mid-walk is out of reach")
        #expect(try trashNames() == [])
    }

    // MARK: Identity

    /// Something takes the trashed folder's place in the Trash before the erase opens it: nothing is erased, and the
    /// item is journaled as trashed, since that is where it is.
    @Test func aFolderSwappedInTheTrashBeforeTheEraseIsNotErased() async throws {
        let folder = try fixture.tmp.directory("home/Library/Caches/moved")
        try fixture.tmp.file("home/Library/Caches/moved/original.bin", size: 10)
        let parked = fixture.tmp.url.appendingPathComponent("parked")
        let service = fixture.guardedService(hook: { item, relative in
            guard relative.isEmpty else { return }
            try? FileManager.default.moveItem(atPath: item, toPath: parked.path)
            try? FileManager.default.createDirectory(atPath: item, withIntermediateDirectories: false)
            FileManager.default.createFile(atPath: item + "/newcomer.bin", contents: Data(count: 10))
        })

        let report = await service.remove([TrashItem(url: folder, expectedIdentity: FileIdentity(url: folder))], mode: .permanent)

        let message = "Moved to the Trash, but not deleted: it changed there. Empty the Trash to finish."
        #expect(report.outcomes == [.failed(folder, message: message)])
        #expect(exists(fixture.trash.appendingPathComponent("moved/newcomer.bin")))
        #expect(exists(parked.appendingPathComponent("original.bin")))
        #expect(await fixture.service().history().map(\.trashedPath) == [fixture.trash.appendingPathComponent("moved").path])
    }

    /// Another file takes the chosen file's name after the pre-flight: it is not deleted.
    @Test func aFileSwappedBeforeItsDeleteIsNotDeleted() async throws {
        let file = try fixture.tmp.file("home/Downloads/setup.dmg", size: 10)
        let parked = fixture.tmp.url.appendingPathComponent("parked.dmg")
        let service = fixture.guardedService(hook: { item, relative in
            guard relative.isEmpty else { return }
            try? FileManager.default.moveItem(atPath: item, toPath: parked.path)
            FileManager.default.createFile(atPath: item, contents: Data(count: 20))
        })

        let report = await service.remove([TrashItem(url: file, expectedIdentity: FileIdentity(url: file))], mode: .permanent)

        #expect(report.outcomes == [.refused(file, .identityChanged)])
        #expect(try Data(contentsOf: file) == Data(count: 20))
        #expect(exists(parked))
        #expect(await fixture.service().history().isEmpty)
    }

    // MARK: Size and depth

    /// 300 levels of 5-character names, past PATH_MAX, built and erased fd-relative.
    @Test func aTreeThreeHundredLevelsDeepIsErased() async throws {
        let folder = try fixture.tmp.directory("home/Library/Caches/deep")
        var fd = open(folder.path, O_RDONLY | O_DIRECTORY)
        for _ in 0..<300 {
            #expect(mkdirat(fd, "level", 0o755) == 0)
            let next = openat(fd, "level", O_RDONLY | O_DIRECTORY)
            close(fd)
            fd = next
        }
        close(openat(fd, "bottom.bin", O_WRONLY | O_CREAT, 0o644))
        close(fd)
        #expect(folder.path.utf8.count + 300 * 6 > Int(MAXPATHLEN))

        let report = await fixture.guardedService().remove([TrashItem(url: folder, expectedIdentity: FileIdentity(url: folder))], mode: .permanent)

        #expect(report.outcomes == [.deleted(original: folder)])
        #expect(try trashNames() == [])
    }

    /// Every name is read before any is removed; 10,000 entries in one folder all go.
    @Test func tenThousandEntriesInOneFolderAreErased() async throws {
        let folder = try fixture.tmp.directory("home/Library/Caches/flat")
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY)
        for index in 0..<10_000 { close(openat(fd, String(format: "f%05d", index), O_WRONLY | O_CREAT, 0o644)) }
        close(fd)

        let report = await fixture.guardedService().remove([TrashItem(url: folder, expectedIdentity: FileIdentity(url: folder))], mode: .permanent)

        #expect(report.outcomes == [.deleted(original: folder)])
        #expect(try trashNames() == [])
    }

    // MARK: Pre-flight

    /// Emptying a folder needs write access to every folder inside it; moving it to the Trash does not.
    @Test(arguments: [DeletionMode.trash, .permanent])
    func anUnwritableFolderInsideNeedsTheAdministratorOnlyToErase(mode: DeletionMode) async throws {
        let folder = try fixture.tmp.directory("home/Library/Caches/mixed")
        try fixture.tmp.file("home/Library/Caches/mixed/mine.bin", size: 10)
        let rootOwned = try fixture.tmp.directory("home/Library/Caches/mixed/stand-in-for-root")
        try fixture.tmp.file("home/Library/Caches/mixed/stand-in-for-root/theirs.bin", size: 10)
        #expect(chmod(rootOwned.path, 0o555) == 0)

        let report = await fixture.guardedService().remove([TrashItem(url: folder, expectedIdentity: FileIdentity(url: folder))], mode: mode)

        if mode == .permanent {
            #expect(report.outcomes == [.refused(folder, .needsAdministrator)])
            #expect(exists(rootOwned.appendingPathComponent("theirs.bin")) && fixture.backendCalls.isEmpty)
        } else {
            #expect(report.outcomes.first?.trashedTo != nil)
        }
    }

    /// A leftover waits for its app: while anything is at the app's path, it is not touched, in either mode.
    @Test(arguments: [DeletionMode.trash, .permanent])
    func anItemWhoseRequiredGonePathExistsIsNotTouched(mode: DeletionMode) async throws {
        let app = try fixture.tmp.directory("Applications/Example.app")
        let leftover = try fixture.tmp.file("home/Library/Caches/com.example.app/blob", size: 10).deletingLastPathComponent()
        let item = TrashItem(url: leftover, expectedIdentity: FileIdentity(url: leftover), requiresGone: app)

        let first = await fixture.guardedService().remove([item], mode: mode)

        #expect(first.outcomes == [.failed(leftover, message: "Not removed, because Example.app is still there.")])
        #expect(exists(leftover.appendingPathComponent("blob")) && fixture.backendCalls.isEmpty)

        // A link at the app's path counts as still there, too.
        try FileManager.default.removeItem(at: app)
        let link = try fixture.tmp.symlink("Applications/Example.app", to: "/nonexistent-macontrol")
        #expect(await fixture.guardedService().remove([item], mode: mode).outcomes == first.outcomes)
        #expect(exists(leftover.appendingPathComponent("blob")))
        try FileManager.default.removeItem(at: link)

        let second = await fixture.guardedService().remove([item], mode: mode)
        #expect(!exists(leftover))
        if mode == .trash {
            #expect(second.outcomes.map(\.trashedTo?.path) == [fixture.trash.appendingPathComponent("com.example.app").path])
        } else {
            #expect(second.outcomes == [.deleted(original: leftover)])
        }
    }

    /// App Management answers EPERM when an app bundle is moved; the Trash move fails, so nothing changed, and the
    /// message says where to allow it. Both error shapes: POSIX, and Cocoa wrapping POSIX.
    @Test(arguments: [DeletionMode.trash, .permanent], [false, true])
    func anAppWhoseTrashMoveIsRefusedByMacOSStaysWhole(mode: DeletionMode, wrapped: Bool) async throws {
        let app = try fixture.tmp.directory("home/Applications/Example.app")
        try fixture.tmp.file("home/Applications/Example.app/Contents/MacOS/Example", size: 10)
        let blocked = TrashBackend { _ in
            let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            throw wrapped ? NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSUnderlyingErrorKey: posix]) : posix
        }
        let service = TrashService(journalURL: fixture.journal, backend: blocked, home: fixture.home)

        let report = await service.remove([TrashItem(url: app, expectedIdentity: FileIdentity(url: app))], mode: mode)

        let message = "macOS blocked this. Allow Macontrol in System Settings > Privacy & Security > App Management."
        #expect(report.outcomes == [.failed(app, message: message)])
        #expect(exists(app.appendingPathComponent("Contents/MacOS/Example")))
        #expect(await service.history().isEmpty)
    }

    // MARK: Trash only (D4)

    /// Each personal database goes to the Trash in permanent mode and is not erased there, one case per path.
    @Test(arguments: [
        "Library/Group Containers/group.com.apple.notes", "Library/Containers/com.apple.Notes",
        "Library/Application Support/AddressBook", "Library/Calendars/Calendar Cache", "Library/Safari/History.db",
        "Library/Application Support/MobileSync/Backup", "Library/Application Support/MobileSync",
    ])
    func personalDatabasesGoToTheTrashInPermanentMode(relative: String) async throws {
        try fixture.tmp.file("home/" + relative + "/inside/data", size: 10)
        let item = fixture.home.appendingPathComponent(relative)
        #expect(ProtectedPaths.trashOnlyReason(for: item, home: fixture.home) != nil)

        let report = await fixture.guardedService().remove([TrashItem(url: item, expectedIdentity: FileIdentity(url: item))], mode: .permanent)

        let destination = try #require(report.outcomes.first?.trashedTo, "\(report.outcomes)")
        #expect(exists(destination.appendingPathComponent("inside/data")))
        #expect(!exists(item))
        #expect(await fixture.service().history().map(\.isPermanent) == [false])
    }

    @Test func anICloudItemGoesToTheTrashInPermanentMode() async throws {
        let doc = try fixture.tmp.file("home/Library/Mobile Documents/com~apple~CloudDocs/Notes/a.txt", size: 10)
        let folder = doc.deletingLastPathComponent()
        let item = TrashItem(url: folder, expectedIdentity: FileIdentity(url: folder))
        #expect(ProtectedPaths.trashOnlyReason(for: folder, home: fixture.home) == "stored in iCloud")

        let refused = await fixture.guardedService().remove([item], mode: .permanent)
        #expect(refused.outcomes == [.refused(folder, .needsCloudConfirmation)])

        let report = await fixture.guardedService().remove([item], mode: .permanent, cloudConfirmed: true)
        #expect(exists(try #require(report.outcomes.first?.trashedTo).appendingPathComponent("a.txt")))
    }

    // MARK: Journal

    /// Lines the administrator helper wrote have no in-app Undo (D12); ordinary lines of the same batch still undo.
    @Test func undoSkipsAdministratorAndPermanentLines() async throws {
        let batch = UUID()
        let mine = try fixture.tmp.file("Trash/mine.txt", size: 10)
        let theirs = try fixture.tmp.file("Trash/theirs.txt", size: 10)
        func line(_ original: String, _ trashed: URL?, administrator: Bool) throws -> String {
            let entry = JournalEntry(
                batch: batch, date: Date(), originalPath: fixture.home.appendingPathComponent(original).path,
                trashedPath: trashed?.path, identity: trashed.flatMap(FileIdentity.init(url:)) ?? FileIdentity(device: 1, inode: 2),
                allocated: 10, restored: false, asAdministrator: administrator
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return String(decoding: try encoder.encode(entry), as: UTF8.self)
        }
        let lines = [try line("mine.txt", mine, administrator: false), try line("theirs.txt", theirs, administrator: true), try line("gone.txt", nil, administrator: false)]
        try FileManager.default.createDirectory(at: fixture.journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fixture.journal)

        let outcomes = await fixture.service().undo(batch: batch)

        #expect(outcomes == [.restored(fixture.home.appendingPathComponent("mine.txt"))])
        #expect(exists(theirs), "the helper's item stays in the Trash")
        #expect(await fixture.service().history().map(\.asAdministrator) == [false, true, false])
    }

    // MARK: Volumes (env-gated: they attach small disk images inside the test's own folder)

    /// A volume mounted inside the folder before the delete: the pre-flight refuses the folder, nothing moves.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_DISK_IMAGE_TESTS"] == "1"))
    func aFolderHoldingAMountedVolumeIsRefused() async throws {
        let folder = try fixture.tmp.directory("home/Library/Caches/withmount")
        let volume = try fixture.attachDiskImage("APFS", at: "home/Library/Caches/withmount/a/mnt")
        let canary = volume.appendingPathComponent("canary.txt")
        try Data(count: 10).write(to: canary)

        let report = await fixture.guardedService().remove([TrashItem(url: folder, expectedIdentity: FileIdentity(url: folder))], mode: .permanent)

        #expect(report.outcomes.first?.refusal?.isProtectedLocation == true, "\(report.outcomes)")
        #expect(exists(canary) && fixture.backendCalls.isEmpty)
    }

    /// A volume mounted inside the folder after the pre-flight, while the folder sits in the Trash: the erase never
    /// enters it, the canary on it stays, and the folder is reported partly deleted.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_DISK_IMAGE_TESTS"] == "1"))
    func aVolumeMountedDuringTheEraseIsNeverEntered() async throws {
        let folder = try fixture.tmp.directory("home/Library/Caches/latemount")
        try fixture.tmp.directory("home/Library/Caches/latemount/a/mnt")
        try fixture.tmp.file("home/Library/Caches/latemount/a/junk.bin", size: 10)
        let fixture = fixture
        let service = fixture.guardedService(hook: { item, relative in
            guard relative.isEmpty, let volume = try? fixture.attachDiskImage("APFS", at: "Trash/latemount/a/mnt") else { return }
            try? Data(count: 10).write(to: volume.appendingPathComponent("canary.txt"))
        })

        let report = await service.remove([TrashItem(url: folder, expectedIdentity: FileIdentity(url: folder))], mode: .permanent)

        guard case .failed(folder, let message) = report.outcomes.first else { Issue.record("\(report.outcomes)"); return }
        #expect(message.hasPrefix("Partly deleted. 1 item inside could not be removed; the rest is in the Trash as \"latemount\"."), "\(message)")
        #expect(message.hasSuffix("First: a/mnt: Cross-device link"), "\(message)")
        #expect(exists(fixture.trash.appendingPathComponent("latemount/a/mnt/canary.txt")))
        #expect(!exists(fixture.trash.appendingPathComponent("latemount/a/junk.bin")))
    }

    /// On a case-sensitive volume `Cache` and `cache` are two folders: deleting one says nothing about the other.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_DISK_IMAGE_TESTS"] == "1"))
    func onACaseSensitiveVolumeATwinFolderIsNotReportedAsDeleted() async throws {
        let volume = try fixture.attachDiskImage("Case-sensitive APFS", at: "volume")
        let upper = volume.appendingPathComponent("Cache")
        let other = volume.appendingPathComponent("cache/b.bin")
        try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data(count: 10).write(to: other)

        let report = await fixture.guardedService().remove(
            [TrashItem(url: upper, expectedIdentity: nil), TrashItem(url: other, expectedIdentity: nil)], mode: .permanent
        )

        #expect(report.outcomes == [.deleted(original: upper), .deleted(original: other)], "\(report.outcomes)")
        #expect(!exists(other) && !exists(upper))
        #expect(exists(other.deletingLastPathComponent()))
    }
}
