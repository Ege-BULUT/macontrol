import Foundation
import Testing
import Uninstaller

@Suite struct InventoryTests {
    @Test func listsAppsOneLevelDeepInEveryApplicationFolder() async throws {
        let fx = try Fixture()
        try fx.app("Editor", id: "com.example.Editor")
        try fx.app("Console Tool", id: "com.example.Console", in: "root/Applications/Utilities")
        try fx.app("Deep", id: "com.example.Deep", in: "root/Applications/Vendor/Nested")
        try fx.app("Helper", id: "com.example.Editor.Helper", in: "root/Applications/Editor.app/Contents/Library/LoginItems")
        try fx.app("Personal", id: "com.example.Personal", in: "home/Applications")
        try fx.app("Chess", id: "com.apple.Chess", in: "root/System/Applications")
        try fx.app("Terminal", id: "com.apple.Terminal", in: "root/System/Applications/Utilities")
        try fx.tmp.symlink("root/Applications/Linked.app", to: fx.root.appendingPathComponent("Applications/Editor.app").path)

        let apps = try await fx.uninstaller().installedApps()

        #expect(Set(apps.map(\.name)) == ["Editor", "Console Tool", "Personal", "Chess", "Terminal"])
        #expect(apps.first { $0.name == "Editor" }?.kind == .thirdParty)
        #expect(apps.first { $0.name == "Editor" }?.bundleIdentifier == "com.example.Editor")
        #expect(apps.filter { $0.kind == .builtIn }.map(\.name).sorted() == ["Chess", "Terminal"])
    }

    /// Date Added is when the app arrived in its folder (Finder's Date Added), not when the bundle was made.
    @Test func dateAddedIsWhenTheAppArrivedNotWhenItWasMade() async throws {
        let fx = try Fixture()
        let bundle = try fx.app("Editor", id: "com.example.Editor")
        let made = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: made], ofItemAtPath: bundle.path)
        let arrived = try #require(try await fx.app(named: "Editor").dateAdded)
        #expect(arrived.timeIntervalSinceNow > -600, "got \(arrived), the bundle was made \(made)")
    }

    /// A receipt alone does not make an app Apple's: the signature must be Apple's, with Apple's team.
    @Test func receiptWithoutApplesSignatureIsThirdParty() async throws {
        let fx = try Fixture()
        try fx.app("GarageBand", id: "com.apple.garageband10")
        try fx.file("root/Applications/GarageBand.app/Contents/_MASReceipt/receipt")

        #expect(try await fx.app(named: "GarageBand").kind == .thirdParty)
    }
}
