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

    // A confirmed cloud delete takes what is inside a provider, never the provider itself.
    @Test func cloudProviderFoldersAreRefusedEvenWhenConfirmed() throws {
        let fixture = try TrashFixture()
        let documents = try fixture.tmp.directory("home/Library/Mobile Documents/iCloud~com~example~App/Documents")
        try fixture.tmp.directory("home/Library/Mobile Documents/com~apple~CloudDocs")
        try fixture.tmp.directory("home/Library/CloudStorage/Dropbox")

        let providers = ["Mobile Documents/com~apple~CloudDocs", "Mobile Documents/iCloud~com~example~App", "CloudStorage/Dropbox"]
        for provider in providers.map({ fixture.home.appendingPathComponent("Library/" + $0) }) {
            #expect(ProtectedPaths.refusal(for: provider, home: fixture.home, cloudConfirmed: true) == .protectedLocation(provider.path))
        }
        #expect(ProtectedPaths.refusal(for: documents, home: fixture.home, cloudConfirmed: true) == nil)
    }

    // Every volume keeps its index, event log and document versions at its root, wherever it is mounted.
    @Test func refusesVolumeSystemFoldersOnEveryVolume() throws {
        let fixture = try TrashFixture()
        for name in [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100"] {
            let inside = try fixture.tmp.file("Volume/\(name)/Store/0001", size: 10)
            let folder = fixture.tmp.url.appendingPathComponent("Volume/" + name)
            #expect(ProtectedPaths.refusal(for: folder, home: fixture.home) == .protectedLocation(folder.path))
            #expect(ProtectedPaths.refusal(for: inside, home: fixture.home) == .protectedLocation(folder.path))
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

    // An item nested past PATH_MAX exists; only its path is out of reach.
    @Test func aDeepItemIsNotReportedMissing() throws {
        let fixture = try TrashFixture()
        let name = String(repeating: "d", count: 60)
        var path = fixture.home.path
        var fd = open(path, O_RDONLY | O_DIRECTORY)
        var middle: Int32 = -1
        for level in 1...20 {
            #expect(mkdirat(fd, name, 0o755) == 0)
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY)
            if level == 10 { middle = fd } else { close(fd) }
            fd = next
            path += "/" + name
        }
        close(fd)
        // Cut the chain in two, so the temporary folder can remove both halves by path.
        defer {
            renameat(middle, name, AT_FDCWD, fixture.tmp.url.appendingPathComponent("tail").path)
            close(middle)
        }

        #expect(path.utf8.count > Int(MAXPATHLEN))
        #expect(ProtectedPaths.refusal(for: URL(fileURLWithPath: path), home: fixture.home) == .needsAdministrator)
    }

    // ARCHITECTURE 5: a folder holding a live volume is refused, or the volume rides into the Trash.
    // Env-gated: attaches a small disk image inside the test's own folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_DISK_IMAGE_TESTS"] == "1"))
    func refusesAFolderThatContainsAMountPoint() throws {
        let fixture = try TrashFixture()
        let projects = try fixture.tmp.directory("home/Projects")
        let mount = try fixture.attachDiskImage("APFS", at: "home/Projects/mnt")

        #expect(ProtectedPaths.refusal(for: mount, home: fixture.home) == .protectedLocation(mount.path))
        #expect(ProtectedPaths.refusal(for: projects, home: fixture.home) == .protectedLocation(mount.path))
        let shouted = fixture.home.appendingPathComponent("PROJECTS")
        #expect(ProtectedPaths.refusal(for: shouted, home: fixture.home) == .protectedLocation(mount.path))
    }

    @Test func missingItemsAreReportedAsMissing() throws {
        let fixture = try TrashFixture()
        let absent = fixture.tmp.url.appendingPathComponent("absent/file.txt")
        #expect(ProtectedPaths.refusal(for: absent, home: fixture.home) == .missing)
    }
    /// The live macOS configuration folders: root-owned and mostly not `restricted`, so before r2 a root caller passed
    /// the policy there (r2: sec 3b). Checked on the folders and on a file inside; the policy only reads.
    @Test(arguments: [
        "/Library/Preferences/SystemConfiguration", "/Library/Preferences/OpenDirectory", "/Library/Application Support/Apple",
        "/Library/Apple", "/Library/Developer/CommandLineTools",
    ])
    func macOSConfigurationFoldersAreNeverTouched(folder: String) {
        for path in [folder, folder + "/preferences.plist"] {
            #expect(ProtectedPaths.refusal(for: URL(fileURLWithPath: path)) == .protectedLocation(folder), "\(path)")
        }
    }

    /// D4: which items a permanent delete sends to the Trash, and the reason the sheet shows.
    @Test func trashOnlyItemsAndTheirReasons() throws {
        let fixture = try TrashFixture()
        let home = fixture.home
        let cases: [(String, String?)] = [
            ("Library/Group Containers/group.com.apple.notes", "holds your notes"),
            ("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite", "holds your notes"),
            ("Library/Containers/com.apple.Notes", "holds your notes"),
            ("Library/Application Support/AddressBook/Sources", "holds your contacts"),
            ("Library/Calendars/Calendar Cache", "holds your calendars"),
            ("Library/Safari/History.db", "holds your Safari data"),
            ("Library/Application Support/MobileSync", "holds iPhone and iPad backups"),
            ("Library/Mobile Documents/com~apple~CloudDocs/a.txt", "stored in iCloud"),
            ("Library/CloudStorage/Dropbox/a.txt", "stored in a cloud folder"),
            ("Library/Group Containers/group.com.apple.notesX", nil),
            ("Library/Caches/com.apple.Safari", nil),
            ("Library/Application Support/AddressBookX", nil),
        ]
        for (relative, reason) in cases {
            try fixture.tmp.file("home/" + relative + "/x")
            #expect(ProtectedPaths.trashOnlyReason(for: home.appendingPathComponent(relative), home: home) == reason, "\(relative)")
        }
    }
}

