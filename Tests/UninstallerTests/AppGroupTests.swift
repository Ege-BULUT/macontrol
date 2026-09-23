import Foundation
import Testing
import Uninstaller

/// Group containers come from the app's signed `application-groups` entitlement, so these fixtures are real,
/// ad-hoc signed bundles (a copy of /usr/bin/true as the executable).
@Suite struct AppGroupTests {
    @Test func groupContainersFromEntitlementsAreFoundAndSharedOnesHeldBack() async throws {
        let fx = try Fixture()
        try signedApp("Writer", id: "com.example.Writer", groups: ["ABCDE12345.com.example.shared", "ABCDE12345.com.example.writer"], in: fx)
        try signedApp("Sheets", id: "com.example.Sheets", groups: ["ABCDE12345.com.example.shared"], in: fx)
        try fx.file("home/Library/Group Containers/ABCDE12345.com.example.writer/Library/data")
        try fx.file("home/Library/Group Containers/ABCDE12345.com.example.shared/Library/data")
        try fx.file("home/Library/Group Containers/ABCDE12345.com.example.unrelated/Library/data")
        try fx.file("home/Library/Application Scripts/ABCDE12345.com.example.writer/script.scpt")

        let plan = try await fx.plan("Writer")

        let library = fx.home.appendingPathComponent("Library")
        #expect(plan.paths(relativeTo: library) == [
            "Application Scripts/ABCDE12345.com.example.writer",
            "Group Containers/ABCDE12345.com.example.shared",
            "Group Containers/ABCDE12345.com.example.writer",
        ])
        #expect(plan.leftovers.allSatisfy { $0.evidence == .appGroup })
        #expect(plan.leftover("Group Containers/ABCDE12345.com.example.shared", in: library)?.note == "Also used by Sheets")
        #expect(plan.leftovers.filter(\.isPreselected).count == 2)
    }

    private func signedApp(_ name: String, id: String, groups: [String], in fx: Fixture) throws {
        let app = try fx.app(name, id: id)
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
    }
}
