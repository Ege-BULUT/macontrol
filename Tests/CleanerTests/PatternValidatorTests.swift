import Cleaner
import Testing

/// F-0032: Kudu accepted `${HOME}`, `/` and `${CACHES}/../..` as rule paths and preselected everything in them.
@Suite struct PatternValidatorTests {
    @Test(arguments: [
        "${HOME}/x",
        "$HOME/Library/Caches/x",
        "/",
        "/Users/Shared/x/*",
        "/Library/Caches/*",
        "Library/Caches/*",
        "~",
        "~/Library/*",
        "~/Library/Caches",
        "~/Documents/*",
        "~/Documents/Projects/build/*",
        "~/desktop/a/b",
        "~/Library/Caches/../..",
        "~/Library/Caches/./x",
        "~/Library/Caches//x",
        "~/Library/Caches/*/x*y/*",
        "~/Library/*/Caches/x",
        "~/Library/Application Support/*",
        "~/Library/Containers/*",
        "~/Library/Mobile Documents/com~apple~CloudDocs/x",
        "~/Library/CloudStorage/GoogleDrive-me/x",
        "~/Library/Application Support/FileProvider/x",
        "~/Library/Caches/~other",
        "/System/Volumes/Data/macOS Install Data/../../Users",
    ])
    func refuses(_ pattern: String) {
        #expect(PatternValidator.problem(with: pattern) != nil)
    }

    @Test(arguments: [
        "~/Library/Caches/*",
        "~/Library/Logs/*",
        "~/Library/Caches/com.apple.*",
        "~/Library/Caches/Google/Chrome",
        "~/Library/Developer/Xcode/DerivedData/*",
        "~/.npm/_cacache/*",
        "/System/Volumes/Data/macOS Install Data",
    ])
    func accepts(_ pattern: String) {
        #expect(PatternValidator.problem(with: pattern) == nil)
    }

    @Test func aRuleWithOneBadPatternIsDroppedWhole() {
        let good = CleanupRule(id: "good", title: "", category: .appCaches, safety: .safe, paths: ["~/Library/Caches/*"], minimumAgeDays: nil, note: "")
        let bad = CleanupRule(id: "bad", title: "", category: .appCaches, safety: .safe, paths: ["~/Library/Caches/x", "~/Library/*"], minimumAgeDays: nil, note: "")

        let (catalog, rejections) = CleanupCatalog(version: 1, rules: [good, bad]).validated()

        #expect(catalog.rules.map(\.id) == ["good"])
        #expect(rejections.map(\.pattern) == ["~/Library/*"])
    }
}
