import Foundation
import Safety
import Testing
import TestSupport
import Uninstaller

@Suite struct UninstallerTests {
    @Test func planFindsBundleIdentifierLeftoversInTheGivenHome() async throws {
        let tmp = try TemporaryDirectory()
        let apps = try tmp.directory("Applications")
        try tmp.file("Applications/Demo.app/Contents/Info.plist", size: 0)
        try PropertyListSerialization
            .data(fromPropertyList: ["CFBundleIdentifier": "com.example.Demo", "CFBundleName": "Demo"], format: .xml, options: 0)
            .write(to: apps.appendingPathComponent("Demo.app/Contents/Info.plist"))
        try tmp.file("home/Library/Caches/com.example.Demo/cache.db", size: 100)
        try tmp.file("home/Library/Caches/com.example.DemoHelper/other.db", size: 100)

        let uninstaller = Uninstaller(
            home: tmp.url.appendingPathComponent("home"),
            applicationFolders: [apps],
            trash: TrashService(journalURL: tmp.url.appendingPathComponent("journal.jsonl"))
        )
        let app = try #require(try await uninstaller.installedApps().first)
        let plan = try await uninstaller.plan(for: app)

        #expect(app.bundleIdentifier == "com.example.Demo")
        #expect(plan.leftovers.map(\.url.lastPathComponent) == ["com.example.Demo"])
    }
}
