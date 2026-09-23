@testable import Cleaner
import Foundation
import Testing

/// Checks over the catalog that ships in the app.
@Suite struct CatalogTests {
    let catalog: CleanupCatalog

    init() throws {
        catalog = try CleanupCatalog.unvalidatedBundled()
    }

    func rule(_ id: String) throws -> CleanupRule {
        try #require(catalog.rules.first { $0.id == id })
    }

    /// F-0032: the shipped rules pass the same validator the app applies at load and before every scan.
    @Test func everyBundledPatternPassesValidation() throws {
        #expect(catalog.validated().rejections == [])
        #expect(try CleanupCatalog.bundled().rules.count == catalog.rules.count)
    }

    @Test func idsAreUniqueAndEveryRuleExplainsItself() {
        #expect(Set(catalog.rules.map(\.id)).count == catalog.rules.count)
        for rule in catalog.rules {
            #expect(!rule.title.isEmpty && !rule.note.isEmpty && !rule.paths.isEmpty, "\(rule.id)")
        }
    }

    /// F-0027: backups, archives and installer data are never preselected or part of a clean.
    @Test func irreplaceableDataIsManual() throws {
        for id in ["ios-device-backups", "xcode-archives", "macos-install-data"] {
            #expect(try rule(id).safety == .manual, "\(id)")
        }
    }

    /// F-0027: Mac Sai offered the whole CoreSimulator/Devices folder, every simulator's data, as junk.
    @Test func simulatorDevicesAreNeverMatched() {
        let patterns = catalog.rules.flatMap(\.paths).map { $0.lowercased() }
        #expect(patterns.allSatisfy { !$0.contains("coresimulator/devices") })
        #expect(patterns.contains("~/library/developer/coresimulator/caches/*"))
    }

    /// F-0033: stores other tools hard-link from, and slow re-downloads, need a look first.
    @Test func sharedStoresAndDeviceSymbolsNeedReview() throws {
        for id in ["pnpm-store", "gradle-caches", "maven-repository", "cargo-registry", "device-support", "apple-caches"] {
            #expect(try rule(id).safety == .review, "\(id)")
        }
    }

    @Test func browserRulesStayInCachesNeverProfiles() {
        for rule in catalog.rules where rule.category == .browsers {
            #expect(rule.paths.allSatisfy { $0.hasPrefix("~/Library/Caches/") }, "\(rule.id)")
        }
    }

    @Test func logsKeepAWeek() throws {
        #expect(try rule("user-logs").minimumAgeDays == 7)
    }

    /// Overlaps resolve by catalog order, so specific rules must come before the catch-all cache rule.
    @Test func catchAllCacheRuleComesAfterEverySpecificCacheRule() throws {
        let order = catalog.rules.map(\.id)
        let catchAll = try #require(order.firstIndex(of: "user-app-caches"))
        let specific = catalog.rules.enumerated().filter { $0.element.paths.contains { $0.hasPrefix("~/Library/Caches/") } && $0.element.id != "user-app-caches" }
        #expect(specific.allSatisfy { $0.offset < catchAll })
    }
}
