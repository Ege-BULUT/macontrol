@testable import Cleaner
import Foundation
import Testing
import TestSupport

@Suite struct CatalogMatcherTests {
    /// Review probe5: the overlap check was O(n²), 2.36 s for 2000 matches. Sorted neighbours make it n log n.
    @Test func thousandsOfMatchesResolveQuickly() throws {
        let home = try TemporaryDirectory()
        for index in 0..<3000 { try home.directory("Library/Caches/app\(index)") }
        let rules = [CleanupRule(id: "caches", title: "", category: .appCaches, safety: .safe, paths: ["~/Library/Caches/*"], minimumAgeDays: nil, note: "")]

        let start = ContinuousClock.now
        let matches = CatalogMatcher(home: home.url).matches(for: rules)

        #expect(matches.count == 3000)
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
