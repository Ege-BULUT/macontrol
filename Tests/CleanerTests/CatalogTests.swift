import Cleaner
import Foundation
import Testing
import TestSupport

@Suite struct CatalogTests {
    @Test func bundledCatalogLoadsWithUniqueIDs() throws {
        let catalog = try CleanupCatalog.bundled()
        #expect(!catalog.rules.isEmpty)
        #expect(Set(catalog.rules.map(\.id)).count == catalog.rules.count)
    }

    @Test func scanFindsOnlyMatchesInsideTheGivenHome() async throws {
        let home = try TemporaryDirectory()
        try home.file("Library/Caches/com.example.App/blob", size: 5000)
        let rule = CleanupRule(
            id: "t", title: "T", category: .appCaches, safety: .safe,
            paths: ["~/Library/Caches/*"], minimumAgeDays: nil, note: ""
        )

        var items: [CleanupItem] = []
        for try await item in Cleaner(catalog: CleanupCatalog(version: 1, rules: [rule]), home: home.url).scan() {
            items.append(item)
        }

        #expect(items.map(\.url.lastPathComponent) == ["com.example.App"])
        #expect(items.first?.measurement.allocated == 8192)
    }
}
