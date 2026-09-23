import Foundation
import MacontrolCore
@testable import MacontrolUI
import ScanEngine
import Testing

@Suite struct OverviewSummaryTests {
    @Test func largestItemsAreSortedCappedAndScaledToTheBiggest() {
        let summary = OverviewSummary(volume: nil, tree: .demo(), cleanItems: [], limit: 3)
        #expect(summary.largest.map(\.name) == ["Library", "Movies", "projects"])
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

        // Demo: two safe items (1.3 + 6.8 GB), one skipped because its app runs, one manual-only.
        let safe = OverviewSummary(volume: nil, tree: nil, cleanItems: CleanModel.demo().items).safeToClean
        #expect(safe?.count == 2)
        #expect(safe?.bytes == 8_100_000_000)
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

        let movies = try #require(model.overview.largest.first { !$0.isFolder })
        model.openInDiskMap(movies)
        #expect(model.diskMap.focus == ScanTree.root)
    }
}
