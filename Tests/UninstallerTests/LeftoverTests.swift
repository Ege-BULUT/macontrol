import Foundation
import Testing
import Uninstaller

@Suite struct LeftoverTests {
    /// F-0011: a name-matching uninstaller trashes ~/Documents/Sketchbook with the app.
    @Test func userFoldersAreNeverSearched() async throws {
        let fx = try Fixture()
        try fx.app("Sketchbook", id: "com.example.Sketchbook")
        for folder in ["Documents", "Desktop", "Downloads", "Music", "Pictures", "Movies"] {
            try fx.file("home/\(folder)/Sketchbook/drawing.png")
            try fx.file("home/\(folder)/com.example.Sketchbook/data")
        }
        try fx.file("home/Library/Mobile Documents/com~apple~CloudDocs/Sketchbook/drawing.png")
        try fx.file("home/Library/Mobile Documents/ABCDE12345~com~example~Sketchbook/Documents/a.sketch")
        try fx.file("root/Users/Shared/Sketchbook/drawing.png")
        try fx.file("home/.sketchbook/config")
        try fx.file("home/Library/Preferences/com.example.Sketchbook.plist")

        let plan = try await fx.plan("Sketchbook")

        #expect(plan.paths(relativeTo: fx.tmp.url) == ["home/Library/Preferences/com.example.Sketchbook.plist"])
    }

    @Test func bundleIdentifierItemsArePreselectedInEveryLibraryFolder() async throws {
        let fx = try Fixture()
        try fx.app("Demo", id: "com.example.Demo")
        let expected = [
            "Application Scripts/com.example.Demo/run.scpt",
            "Application Support/com.example.Demo/db.sqlite",
            "Caches/com.example.Demo/Cache.db",
            "Caches/com.example.Demo.ShipIt/update.zip",
            "Cookies/com.example.Demo.binarycookies",
            "HTTPStorages/com.example.Demo/httpstorages.sqlite",
            "HTTPStorages/com.example.Demo.binarycookies",
            "Logs/com.example.demo/log.txt",
            "Preferences/ByHost/com.example.Demo.0A1B2C3D-0000-1111-2222-333344445555.plist",
            "Preferences/com.example.Demo.plist",
            "Saved Application State/com.example.Demo.savedState/windows.plist",
            "WebKit/com.example.Demo/WebsiteData/LocalStorage/x",
        ]
        for path in expected { try fx.file("home/Library/\(path)") }
        // Not the app's: a longer identifier without a dot, a two-part vendor prefix, another app entirely.
        try fx.file("home/Library/Caches/com.example.DemoHelper/cache.db")
        try fx.file("home/Library/Caches/com.example/cache.db")
        try fx.file("home/Library/Preferences/com.example.Other.plist")

        let plan = try await fx.plan("Demo")

        let library = fx.home.appendingPathComponent("Library")
        let topLevel = Set(expected.map { path in
            path.hasPrefix("Preferences/ByHost") ? path : path.split(separator: "/").prefix(2).joined(separator: "/")
        })
        #expect(Set(plan.paths(relativeTo: library)) == topLevel)
        #expect(plan.leftovers.allSatisfy { $0.isPreselected && $0.evidence == .bundleIdentifier })
    }

    /// F-0022: uninstalling LuLu trashed the whole Objective-See folder, BlockBlock's rules included.
    @Test func vendorFolderContributesOnlyTheAppsOwnSubfolder() async throws {
        let fx = try Fixture()
        try fx.app("LuLu", id: "com.objective-see.lulu.app")
        try fx.app("BlockBlock", id: "com.objective-see.blockblock")
        try fx.file("home/Library/Application Support/Objective-See/LuLu/rules.plist")
        try fx.file("home/Library/Application Support/Objective-See/BlockBlock/rules.plist")
        try fx.file("home/Library/Preferences/com.objective-see.blockblock.plist")

        let plan = try await fx.plan("LuLu")

        let library = fx.home.appendingPathComponent("Library")
        #expect(plan.paths(relativeTo: library) == ["Application Support/Objective-See/LuLu"])
        #expect(plan.leftovers.first?.evidence == .exactName)
        #expect(plan.leftovers.first?.isPreselected == false)
    }

    @Test func containersAreAttributedByTheirMetadata() async throws {
        let fx = try Fixture()
        try fx.app("Demo", id: "com.example.Demo")
        let uuid = "6F1A7C2E-8B3D-4E5F-9A0B-1C2D3E4F5A6B"
        try fx.write(["MCMMetadataIdentifier": "com.example.Demo"], to: "home/Library/Containers/\(uuid)/.com.apple.containermanagerd.metadata.plist")
        try fx.write(["MCMMetadataIdentifier": "com.example.Demo.ShareExtension"], to: "home/Library/Containers/com.example.Demo.ShareExtension/.com.apple.containermanagerd.metadata.plist")
        // Named like the app, but containermanagerd records another owner.
        try fx.write(["MCMMetadataIdentifier": "com.example.Impostor"], to: "home/Library/Containers/com.example.Demo/.com.apple.containermanagerd.metadata.plist")
        try fx.write(["MCMMetadataIdentifier": "com.example.Other"], to: "home/Library/Containers/0B1C2D3E-4F5A-6B7C-8D9E-0F1A2B3C4D5E/.com.apple.containermanagerd.metadata.plist")

        let plan = try await fx.plan("Demo")

        let containers = fx.home.appendingPathComponent("Library/Containers")
        #expect(plan.paths(relativeTo: containers) == ["6F1A7C2E-8B3D-4E5F-9A0B-1C2D3E4F5A6B", "com.example.Demo.ShareExtension"])
        #expect(plan.leftovers.allSatisfy { $0.evidence == .containerMetadata && $0.isPreselected })
    }

    @Test func exactNameIsShownUnselectedAndSubstringsNeverMatch() async throws {
        let fx = try Fixture()
        try fx.app("Notes", id: "com.example.notes", info: ["CFBundleExecutable": "notes-bin"])
        try fx.file("home/Library/Application Support/notes/data.json")
        try fx.file("home/Library/Logs/notes-bin/log.txt")
        try fx.file("home/Library/Application Support/NotesPlus/data.json")
        try fx.file("home/Library/Application Support/My Notes/data.json")
        try fx.file("home/Library/Caches/Sticky Notes/cache.db")

        let plan = try await fx.plan("Notes")

        let library = fx.home.appendingPathComponent("Library")
        #expect(plan.paths(relativeTo: library) == ["Application Support/notes", "Logs/notes-bin"])
        #expect(plan.leftovers.allSatisfy { $0.evidence == .exactName && !$0.isPreselected })
    }

    /// PyCharm Professional (`com.jetbrains.pycharm`) must not take PyCharm CE's (`com.jetbrains.pycharm.ce`) data,
    /// and a second copy of the same app keeps what both copies use.
    @Test func itemsAnotherInstalledAppUsesAreNotedAndUnselected() async throws {
        let fx = try Fixture()
        try fx.app("PyCharm", id: "com.jetbrains.pycharm")
        try fx.app("PyCharm CE", id: "com.jetbrains.pycharm.ce")
        try fx.file("home/Library/Caches/com.jetbrains.pycharm/cache")
        try fx.file("home/Library/Caches/com.jetbrains.pycharm.ce/cache")

        let plan = try await fx.plan("PyCharm")
        let caches = fx.home.appendingPathComponent("Library/Caches")
        #expect(plan.leftover("com.jetbrains.pycharm", in: caches)?.isPreselected == true)
        #expect(plan.leftover("com.jetbrains.pycharm.ce", in: caches)?.note == "Also used by PyCharm CE")
        #expect(plan.leftover("com.jetbrains.pycharm.ce", in: caches)?.isPreselected == false)

        try fx.app("PyCharm", id: "com.jetbrains.pycharm", in: "home/Applications")
        let secondCopy = try await fx.uninstaller().plan(for: fx.app(named: "PyCharm"))
        #expect(secondCopy.leftover("com.jetbrains.pycharm", in: caches)?.note == "Also used by PyCharm")
    }

    @Test func systemLibraryItemsNeedAnAdministrator() async throws {
        let fx = try Fixture()
        let app = try fx.app("Demo", id: "com.example.Demo")
        try fx.file("root/Library/Application Support/com.example.Demo/state")
        try fx.file("root/Library/Caches/com.example.Demo/cache")
        try fx.file("root/Library/PrivilegedHelperTools/com.example.Demo.helper")
        try fx.launchdJob("root/Library/LaunchDaemons/com.example.Demo.helper.plist", label: "com.example.Demo.helper",
                          program: fx.root.appendingPathComponent("Library/PrivilegedHelperTools/com.example.Demo.helper").path)
        try fx.launchdJob("root/Library/LaunchAgents/com.vendor.updater.plist", label: "com.vendor.updater",
                          program: app.appendingPathComponent("Contents/MacOS/updater").path)

        let plan = try await fx.plan("Demo")

        let library = fx.root.appendingPathComponent("Library")
        #expect(plan.paths(relativeTo: library) == [
            "Application Support/com.example.Demo", "Caches/com.example.Demo", "LaunchAgents/com.vendor.updater.plist",
            "LaunchDaemons/com.example.Demo.helper.plist", "PrivilegedHelperTools/com.example.Demo.helper",
        ])
        // Preselection no longer depends on it (T-0075): the helper takes them, and the UI disables them without one.
        #expect(plan.leftovers.allSatisfy { $0.needsAdministrator })
    }

    @Test func launchdJobsAreFoundByProgramLabelAndAssociation() async throws {
        let fx = try Fixture()
        let app = try fx.app("Demo", id: "com.example.Demo")
        let other = try fx.app("Other", id: "com.example.Other")
        let agents = "home/Library/LaunchAgents"
        try fx.launchdJob("\(agents)/com.vendor.demo-agent.plist", label: "com.vendor.demo-agent",
                          program: app.appendingPathComponent("Contents/MacOS/agent").path)
        // Orphan: its program is gone, but the label is the app's. KnockKnock drops these (F-0072).
        try fx.launchdJob("\(agents)/com.example.Demo.updater.plist", label: "com.example.Demo.updater",
                          program: fx.home.appendingPathComponent("gone/updater").path)
        try fx.write(["Label": "com.vendor.associated", "Program": "/usr/bin/true", "AssociatedBundleIdentifiers": "com.example.Demo"],
                     to: "\(agents)/com.vendor.associated.plist")
        try fx.launchdJob("\(agents)/com.example.Demo.launcher.plist", label: "com.example.Demo.launcher",
                          program: other.appendingPathComponent("Contents/MacOS/Other").path)
        try fx.launchdJob("\(agents)/com.example.Other.agent.plist", label: "com.example.Other.agent",
                          program: other.appendingPathComponent("Contents/MacOS/agent").path)

        let plan = try await fx.plan("Demo")

        let folder = fx.home.appendingPathComponent("Library/LaunchAgents")
        #expect(plan.paths(relativeTo: folder) == [
            "com.example.Demo.launcher.plist", "com.example.Demo.updater.plist",
            "com.vendor.associated.plist", "com.vendor.demo-agent.plist",
        ])
        #expect(plan.leftovers.allSatisfy { $0.evidence == .launchdJob })
        #expect(plan.leftovers.map(\.launchdLabel) == [
            "com.example.Demo.launcher", "com.example.Demo.updater", "com.vendor.associated", "com.vendor.demo-agent",
        ])
        #expect(plan.leftover("com.example.Demo.launcher.plist", in: folder)?.note == "Starts Other")
        #expect(plan.leftovers.filter(\.isPreselected).count == 3)
    }

    /// A shared updater (Microsoft AutoUpdate, Keystone) serves every app it lists. Removing Word must not boot out
    /// and trash the agent Excel still uses.
    @Test func agentAssociatedWithAnotherInstalledAppIsNotedAndUnselected() async throws {
        let fx = try Fixture()
        let word = try fx.app("Word", id: "com.microsoft.Word")
        try fx.app("Excel", id: "com.microsoft.Excel")
        let agents = "home/Library/LaunchAgents"
        try fx.write([
            "Label": "com.microsoft.update.agent",
            "Program": "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/agent",
            "AssociatedBundleIdentifiers": ["com.microsoft.Word", "com.microsoft.Excel"],
        ], to: "\(agents)/com.microsoft.update.agent.plist")
        try fx.write([
            "Label": "com.microsoft.Word.helper", "Program": word.appendingPathComponent("Contents/MacOS/helper").path,
            "AssociatedBundleIdentifiers": ["com.microsoft.Excel"],
        ], to: "\(agents)/com.microsoft.Word.helper.plist")

        let plan = try await fx.plan("Word")

        let folder = fx.home.appendingPathComponent("Library/LaunchAgents")
        #expect(plan.paths(relativeTo: folder) == ["com.microsoft.Word.helper.plist", "com.microsoft.update.agent.plist"])
        #expect(plan.leftovers.allSatisfy { $0.note == "Also used by Excel" && !$0.isPreselected })
    }

    /// PyInstaller's default CFBundleIdentifier is the app's name. A one-word identifier is a name, so what it
    /// matches is shown unselected, like any exact name (F-0011, F-0022).
    @Test func singleWordIdentifierIsNotEvidence() async throws {
        let fx = try Fixture()
        try fx.app("Notes", id: "Notes")
        try fx.file("home/Library/Application Support/Notes/notes.sqlite")
        try fx.file("home/Library/Caches/notes/cache.db")
        try fx.file("home/Library/Preferences/Notes.plist")
        try fx.write(["MCMMetadataIdentifier": "Notes"], to: "home/Library/Containers/Notes/.com.apple.containermanagerd.metadata.plist")

        let plan = try await fx.plan("Notes")

        let library = fx.home.appendingPathComponent("Library")
        #expect(plan.paths(relativeTo: library) == ["Application Support/Notes", "Caches/notes"])
        #expect(plan.leftovers.allSatisfy { $0.evidence == .exactName && !$0.isPreselected })
    }

    @Test func bundleAgentsDaemonsAndReceiptsAreReported() async throws {
        let fx = try Fixture()
        try fx.app("Demo", id: "com.example.Demo")
        let contents = "root/Applications/Demo.app/Contents/Library"
        try fx.write(["Label": "com.example.Demo.agent", "BundleProgram": "Contents/MacOS/agent"], to: "\(contents)/LaunchAgents/com.example.Demo.agent.plist")
        try fx.write(["Label": "com.example.Demo.daemon", "BundleProgram": "Contents/MacOS/daemon"], to: "\(contents)/LaunchDaemons/com.example.Demo.daemon.plist")
        try fx.write(["PackageIdentifier": "com.example.Demo.pkg"], to: "root/private/var/db/receipts/com.example.Demo.pkg.plist")
        try fx.write(["PackageIdentifier": "com.example.Other.pkg"], to: "root/private/var/db/receipts/com.example.Other.pkg.plist")

        let plan = try await fx.plan("Demo")

        #expect(plan.bundleLaunchdLabels == ["com.example.Demo.agent"])
        #expect(plan.notes.count == 2)
        #expect(plan.notes.contains { $0.contains("com.example.Demo.daemon") && $0.contains("root") })
        #expect(plan.notes.contains { $0.contains("package com.example.Demo.pkg") })
        #expect(plan.leftovers.isEmpty)
    }

    /// A label in the bundle's own plist is text the bundle ships: it is booted out only when the job runs the
    /// bundle's program, never another vendor's (here Keystone's updater, outside the bundle).
    @Test func bundleLabelsCountOnlyWhenTheJobRunsTheBundlesOwnProgram() async throws {
        let fx = try Fixture()
        let app = try fx.app("Demo", id: "com.example.Demo")
        let agents = "root/Applications/Demo.app/Contents/Library/LaunchAgents"
        try fx.write(["Label": "com.example.Demo.login", "BundleProgram": "Contents/MacOS/login"], to: "\(agents)/login.plist")
        try fx.launchdJob("\(agents)/helper.plist", label: "com.example.Demo.helper",
                          program: app.appendingPathComponent("Contents/MacOS/helper").path)
        try fx.launchdJob("\(agents)/keystone.plist", label: "com.google.keystone.agent",
                          program: "/Users/me/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdateAgent")
        try fx.write(["Label": "com.example.escape", "BundleProgram": "../../usr/bin/true"], to: "\(agents)/escape.plist")
        try fx.launchdJob("\(agents)/climb.plist", label: "com.example.climb",
                          program: app.appendingPathComponent("../Other.app/Contents/MacOS/other").path)

        let plan = try await fx.plan("Demo")

        #expect(plan.bundleLaunchdLabels == ["com.example.Demo.helper", "com.example.Demo.login"])
    }
}
