import Foundation
@testable import MacontrolUI
import ScanEngine
import Testing
import TestSupport

@Suite struct ShellTests {
    @Test func sectionShortcutsAreCommandOneToSix() {
        #expect(SidebarItem.allCases.map { String($0.shortcut.character) } == ["1", "2", "3", "4", "5", "6"])
        #expect(SidebarItem.debloat.shortcut == "5" && SidebarItem.history.shortcut == "6")
    }

    /// Walking "/" counts the Data volume twice through firmlinks (F-0031).
    @Test func startupDiskScopeWalksTheDataVolume() {
        #expect(ScanScope.startupDisk.url.path == "/System/Volumes/Data")
        #expect(ScanScope.home.url == FileManager.default.homeDirectoryForCurrentUser)
    }

    @Test func scanScopeDrivesTheDiskMap() async throws {
        let folder = try TemporaryDirectory()
        try folder.file("a/big.bin", size: 300_000)
        try folder.file("b/small.bin", size: 10_000)
        let model = AppModel.demo()
        let diskMap = DiskMapModel(engine: ScanEngine(), trash: nil)
        let shell = AppModel(
            fullDiskAccess: .granted, volume: nil, diskMap: diskMap,
            clean: model.clean, uninstall: model.uninstall, history: model.history
        )

        shell.scan(.folder(folder.url))
        #expect(shell.isScanning)
        #expect(shell.scope == .folder(folder.url))
        for _ in 0..<500 where shell.isScanning {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!shell.isScanning)
        let tree = try #require(diskMap.tree)
        #expect(tree.rootURL == folder.url)
        #expect(tree.allocatedSize(of: 0) >= 310_000)
        #expect(shell.volumeReadAt != nil, "volume numbers refresh after a scan")
    }

    @Test func stoppingEndsTheScanState() throws {
        let folder = try TemporaryDirectory()
        let shell = AppModel.demo()
        shell.scan(.folder(folder.url))
        shell.stopScan()
        #expect(!shell.isScanning)
    }
}
