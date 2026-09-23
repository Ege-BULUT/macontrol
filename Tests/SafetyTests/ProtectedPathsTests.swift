import Darwin
import Foundation
import Safety
import Testing
import TestSupport

/// Policy checks only read; nothing here moves a file.
@Suite struct ProtectedPathsTests {
    let realHome = FileManager.default.homeDirectoryForCurrentUser

    @Test func refusesRootHomeLibraryAndTheFoldersThatHoldThem() {
        for path in ["/", "/Users", "/Applications", "/Library", "/System/Volumes/Data", realHome.path, realHome.path + "/Library",
                     realHome.path + "/Library/Caches", realHome.path + "/Documents"] {
            let reason = ProtectedPaths.refusal(for: URL(fileURLWithPath: path))
            #expect(reason?.isProtectedLocation == true, "\(path) -> \(String(describing: reason))")
        }
    }

    // F-0039: realpath() keeps this spelling; F_GETPATH on the parent resolves it to the home folder.
    @Test func refusesHomeReachedThroughTheDataVolume() {
        let twin = URL(fileURLWithPath: "/System/Volumes/Data" + realHome.path)
        #expect(ProtectedPaths.refusal(for: twin) == .protectedLocation(realHome.path))
        let library = twin.appendingPathComponent("Library")
        #expect(ProtectedPaths.refusal(for: library) == .protectedLocation(realHome.path + "/Library"))
    }

    // F-0024: children of never-touch areas are refused, not just the exact folder.
    @Test func refusesInsideNeverTouchAreas() throws {
        let fixture = try TrashFixture()
        let keychain = try fixture.tmp.file("home/Library/Keychains/login.keychain-db", size: 10)
        let key = try fixture.tmp.file("home/.ssh/id_ed25519", size: 10)
        let photo = try fixture.tmp.file("elsewhere/Trip.photoslibrary/originals/1.heic", size: 10)
        let trashed = try fixture.tmp.file("home/.Trash/old.txt", size: 10)
        let volumeTrash = try fixture.tmp.file("Volume/.Trashes/501/old.txt", size: 10)
        let home = fixture.home.path

        #expect(ProtectedPaths.refusal(for: keychain, home: fixture.home) == .protectedLocation(home + "/Library/Keychains"))
        #expect(ProtectedPaths.refusal(for: key, home: fixture.home) == .protectedLocation(home + "/.ssh"))
        #expect(ProtectedPaths.refusal(for: photo, home: fixture.home)?.isProtectedLocation == true)
        #expect(ProtectedPaths.refusal(for: trashed, home: fixture.home) == .protectedLocation(home + "/.Trash"))
        #expect(ProtectedPaths.refusal(for: volumeTrash, home: fixture.home)?.isProtectedLocation == true)
        #expect(ProtectedPaths.refusal(for: URL(fileURLWithPath: "/usr/bin/true")) == .protectedLocation("/usr"))
        #expect(ProtectedPaths.refusal(for: URL(fileURLWithPath: "/private/var/vm/sleepimage")) == .protectedLocation("/private/var/vm"))
        // /usr/local is carved out of /usr: an absent item there is merely missing.
        #expect(ProtectedPaths.refusal(for: URL(fileURLWithPath: "/usr/local/macontrol-absent-\(UUID())")) == .missing)
    }

    @Test func refusesThroughASymlinkedParent() throws {
        let fixture = try TrashFixture()
        try fixture.tmp.file("home/Library/Keychains/login.keychain-db", size: 10)
        let link = try fixture.tmp.symlink("shortcut", to: fixture.home.appendingPathComponent("Library").path)
        let viaLink = link.appendingPathComponent("Keychains/login.keychain-db")

        #expect(ProtectedPaths.refusal(for: viaLink, home: fixture.home) == .protectedLocation(fixture.home.path + "/Library/Keychains"))
        // The link itself is an ordinary item: trashing it moves only the link.
        #expect(ProtectedPaths.refusal(for: link, home: fixture.home) == nil)
    }

    @Test func refusesDotDotSegments() throws {
        let fixture = try TrashFixture()
        try fixture.tmp.directory("home/Library/Caches/app")
        try fixture.tmp.file("home/Library/Keychains/login.keychain-db", size: 10)
        let library = URL(fileURLWithPath: fixture.home.path + "/Library/Caches/..")
        let keychain = URL(fileURLWithPath: fixture.home.path + "/Library/Caches/app/../../Keychains/login.keychain-db")

        #expect(ProtectedPaths.refusal(for: library, home: fixture.home) == .protectedLocation(fixture.home.path + "/Library"))
        #expect(ProtectedPaths.refusal(for: keychain, home: fixture.home) == .protectedLocation(fixture.home.path + "/Library/Keychains"))
    }

    @Test func refusesAFolderThatContainsHome() throws {
        let fixture = try TrashFixture()
        #expect(ProtectedPaths.refusal(for: fixture.tmp.url, home: fixture.home)?.isProtectedLocation == true)
    }

    @Test func cloudItemsNeedConfirmation() throws {
        let fixture = try TrashFixture()
        let drive = try fixture.tmp.file("home/Library/Mobile Documents/com~apple~CloudDocs/Notes.txt", size: 10)
        let dropbox = try fixture.tmp.file("home/Library/CloudStorage/Dropbox/Report.pdf", size: 10)

        for url in [drive, dropbox] {
            #expect(ProtectedPaths.refusal(for: url, home: fixture.home) == .needsCloudConfirmation)
            #expect(ProtectedPaths.refusal(for: url, home: fixture.home, cloudConfirmed: true) == nil)
        }
    }

    @Test func aFolderWeCannotWriteNeedsAdministrator() throws {
        let fixture = try TrashFixture()
        let file = try fixture.tmp.file("readonly/file.txt", size: 10)
        let folder = file.deletingLastPathComponent()
        chmod(folder.path, 0o555)
        defer { chmod(folder.path, 0o755) }

        #expect(ProtectedPaths.refusal(for: file, home: fixture.home) == .needsAdministrator)
    }

    @Test func missingItemsAreReportedAsMissing() throws {
        let fixture = try TrashFixture()
        let absent = fixture.tmp.url.appendingPathComponent("absent/file.txt")
        #expect(ProtectedPaths.refusal(for: absent, home: fixture.home) == .missing)
    }
}
