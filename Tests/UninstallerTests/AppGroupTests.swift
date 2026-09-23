import Foundation
import Testing
@testable import Uninstaller

/// Group containers come from the app's signed `application-groups` entitlement, so these fixtures are real,
/// ad-hoc signed bundles (a copy of /usr/bin/true as the executable).
@Suite struct AppGroupTests {
    @Test func groupContainersFromEntitlementsAreFoundAndSharedOnesHeldBack() async throws {
        let fx = try Fixture()
        try signedApp("Writer", id: "com.example.Writer", groups: ["group.com.example.shared", "group.com.example.writer"], in: fx)
        try signedApp("Sheets", id: "com.example.Sheets", groups: ["group.com.example.shared"], in: fx)
        try groupContainer("group.com.example.writer", in: fx)
        try groupContainer("group.com.example.shared", in: fx)
        try groupContainer("group.com.example.unrelated", in: fx)
        try fx.file("home/Library/Application Scripts/group.com.example.writer/script.scpt")

        let plan = try await fx.plan("Writer")

        let library = fx.home.appendingPathComponent("Library")
        #expect(plan.paths(relativeTo: library) == [
            "Application Scripts/group.com.example.writer",
            "Group Containers/group.com.example.shared",
            "Group Containers/group.com.example.writer",
        ])
        #expect(plan.leftovers.allSatisfy { $0.evidence == .appGroup })
        #expect(plan.leftover("Group Containers/group.com.example.shared", in: library)?.note == "Also used by Sheets")
        #expect(plan.leftovers.filter(\.isPreselected).count == 2)
    }

    /// Group names are untrusted text from the bundle. An empty entry (an undefined `$(APP_GROUP)` build setting)
    /// named the whole Group Containers and Application Scripts folders, and `../../Documents` named ~/Documents,
    /// all preselected.
    @Test func malformedAppGroupNeverNamesAFolderOutsideItsOwnContainer() async throws {
        let fx = try Fixture()
        try signedApp("Writer", id: "com.example.Writer", groups: ["", ".", "..", "../../Documents", "a/b", "group.x/../../../Documents"], in: fx)
        try groupContainer("group.com.other.app", in: fx)
        try fx.file("home/Library/Application Scripts/com.other.app/script.scpt")
        try fx.file("home/Library/Group Containers/a/b/data")
        try fx.file("home/Library/Application Scripts/a/b/script.scpt")
        try fx.file("home/Library/Application Scripts/group.x/script.scpt")
        try fx.file("home/Documents/thesis.docx")

        let plan = try await fx.plan("Writer")

        #expect(plan.leftovers.isEmpty, "\(plan.leftovers.map(\.url.path))")
    }

    /// A folder named like the group is taken only when containermanagerd records it as that group's container.
    @Test func groupContainerNeedsItsOwnMetadata() async throws {
        let fx = try Fixture()
        try signedApp("Writer", id: "com.example.Writer", groups: ["group.com.example.writer", "group.com.example.bare"], in: fx)
        try fx.write(["MCMMetadataIdentifier": "group.com.example.other"],
                     to: "home/Library/Group Containers/group.com.example.writer/\(LeftoverFinder.containerMetadata)")
        try fx.file("home/Library/Group Containers/group.com.example.bare/Library/data")

        let plan = try await fx.plan("Writer")

        #expect(plan.leftovers.isEmpty, "\(plan.leftovers.map(\.url.path))")
    }

    /// Built-in apps count as other users of a group: an app listing `group.com.apple.notes` must not take Notes' store.
    @Test func groupSharedWithABuiltInAppIsNotPreselected() async throws {
        let fx = try Fixture()
        try signedApp("Notes", id: "com.apple.Notes", groups: ["group.com.apple.notes"], in: fx, folder: "root/System/Applications")
        try signedApp("NoteSync", id: "com.example.NoteSync", groups: ["group.com.apple.notes"], in: fx)
        try groupContainer("group.com.apple.notes", in: fx)

        let plan = try await fx.plan("NoteSync")

        let store = try #require(plan.leftovers.first { $0.url.lastPathComponent == "group.com.apple.notes" })
        #expect(store.note == "Also used by Notes")
        #expect(store.isPreselected == false)
    }

    /// Application Scripts has no metadata, so the group's shape guards it: an entry that is another app's identifier
    /// would take that app's folder (Mail keeps the user's rule scripts in Application Scripts/com.apple.mail).
    @Test func groupThatIsABundleIdNeverTakesThatAppsScripts() async throws {
        let fx = try Fixture()
        try signedApp("Writer", id: "com.example.Writer", groups: ["com.apple.mail"], in: fx)
        try fx.file("home/Library/Application Scripts/com.apple.mail/Sort newsletters.scpt")

        let plan = try await fx.plan("Writer")

        #expect(plan.leftovers.isEmpty, "\(plan.leftovers.map(\.url.path))")
    }

    /// Ad-hoc signing carries no team, so the team-prefixed form is checked here directly.
    @Test func appGroupsAreGroupDotOrTheAppsOwnTeam() {
        #expect(LeftoverFinder.isAppGroup("group.com.example.shared", team: nil))
        #expect(LeftoverFinder.isAppGroup("ABCDE12345.com.example.shared", team: "ABCDE12345"))
        #expect(!LeftoverFinder.isAppGroup("ABCDE12345.com.example.shared", team: "ZYXWV98765"))
        #expect(!LeftoverFinder.isAppGroup("ABCDE12345.com.example.shared", team: nil))
        for malformed in ["", ".", "..", "com.apple.mail", "group./../Documents", "group.a\0b"] {
            #expect(!LeftoverFinder.isAppGroup(malformed, team: ""), "\(malformed)")
        }
    }

    private func groupContainer(_ group: String, in fx: Fixture) throws {
        try fx.write(["MCMMetadataIdentifier": group], to: "home/Library/Group Containers/\(group)/\(LeftoverFinder.containerMetadata)")
        try fx.file("home/Library/Group Containers/\(group)/Library/data")
    }

    private func signedApp(_ name: String, id: String, groups: [String], in fx: Fixture, folder: String = "root/Applications") throws {
        let app = try fx.app(name, id: id, in: folder)
        let executable = app.appendingPathComponent("Contents/MacOS/\(name)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let entitlements = try fx.write(["com.apple.security.application-groups": groups], to: "\(name).entitlements")

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--entitlements", entitlements.path, app.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0)
        try #require(AppBundle(url: app).appGroups == groups)
    }
}
