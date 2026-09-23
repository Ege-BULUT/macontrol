import Foundation
import MacontrolCore
@testable import MacontrolUI
import ScanEngine
import Testing

@Suite struct OverviewSummaryTests {
    @Test func largestItemsAreSortedCappedAndScaledToTheBiggest() {
        let summary = OverviewSummary(volume: nil, tree: .demo(), cleanItems: [], limit: 3)
        #expect(summary.largest.map(\.name) == ["Library", "Pictures", "Movies"])
        #expect(summary.largest.first?.share == 1)
        #expect(summary.largest.map(\.bytes) == summary.largest.map(\.bytes).sorted(by: >))
        #expect(summary.largest.first?.isFolder == true)
        #expect(summary.scannedRoot == "demo")
        #expect(AppModel.demo().overview.scannedRoot == "Home")
    }

    @Test func noScanMeansNoLargestItems() {
        let summary = OverviewSummary(volume: nil, tree: nil, cleanItems: [])
        #expect(summary.largest.isEmpty)
        #expect(summary.scannedRoot == nil)
    }

    @Test func safeToCleanCountsOnlyPreselectedItemsAndWaitsForAScan() {
        #expect(OverviewSummary(volume: nil, tree: nil, cleanItems: []).safeToClean == nil)

        // Demo: six safe items; skipped, cautioned, review and manual rows do not count.
        let safe = OverviewSummary(volume: nil, tree: nil, cleanItems: CleanModel.demo().items).safeToClean
        #expect(safe?.count == 6)
        #expect(safe?.bytes == 13_330_000_000)
    }

    @Test func purgeableSpaceIsNeverAddedToAvailable() throws {
        let volume = VolumeSummary(name: "HD", capacity: 1000, available: 200, availableForImportantUsage: 350)
        let capacity = try #require(OverviewSummary(volume: volume, tree: nil, cleanItems: []).capacity)
        #expect(capacity.available == 200)
        #expect(capacity.used == 800)
        #expect(capacity.purgeable == 150)
        #expect(capacity.usedFraction == 0.8)
    }

    @Test func availableAboveCapacityDoesNotUnderflow() throws {
        let volume = VolumeSummary(name: "HD", capacity: 100, available: 120, availableForImportantUsage: 120)
        let capacity = try #require(OverviewSummary(volume: volume, tree: nil, cleanItems: []).capacity)
        #expect(capacity.used == 0)
    }

    @Test func openingAFolderDrillsTheMapIntoIt() throws {
        let model = AppModel.demo()
        let projects = try #require(model.overview.largest.first { $0.name == "projects" })
        model.openInDiskMap(projects)
        #expect(model.selection == .diskMap)
        #expect(model.diskMap.focus == projects.id)

        // The demo's top level holds only folders, so a file row is made up.
        var file = projects
        file.isFolder = false
        model.openInDiskMap(file)
        #expect(model.diskMap.focus == ScanTree.root)
    }
}
