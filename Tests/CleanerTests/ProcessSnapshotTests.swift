@testable import Cleaner
import Foundation
import Testing
import TestSupport

@Suite struct ProcessSnapshotTests {
    /// Review issue 8: swift, xcodebuild and sourcekit-lsp live inside Xcode.app but are not Xcode.
    @Test func onlyABundlesMainExecutableCarriesItsIdentity() throws {
        let folder = try TemporaryDirectory()
        let info = ["CFBundleIdentifier": "com.example.Tool", "CFBundleName": "Tool", "CFBundleExecutable": "Tool"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: folder.file("Tool.app/Contents/Info.plist"))
        let main = try folder.file("Tool.app/Contents/MacOS/Tool")
        let tool = try folder.file("Tool.app/Contents/Developer/usr/bin/swift")

        #expect(ProcessSnapshot.runningApp(executable: main.path) == RunningApp(bundleIdentifier: "com.example.Tool", bundleName: "Tool", executableName: "Tool"))
        #expect(ProcessSnapshot.runningApp(executable: tool.path) == RunningApp(bundleIdentifier: nil, bundleName: nil, executableName: "swift"))
    }

    /// Every process of this user lists its open files; none fall back to "could not check".
    @Test func liveSnapshotInspectsEveryProcess() {
        let snapshot = ProcessSnapshot.current(under: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(!snapshot.apps.isEmpty)
        #expect(snapshot.uninspected == [])
    }
}
