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
        // Never-touch areas (ARCHITECTURE section 5) and app data: refused because no allowed root holds them (review probe3).
        "~/.ssh/keys/*",
        "~/.gnupg/private-keys-v1.d/*",
        "~/Library/Keychains/ABCD/*",
        "~/Library/Mail/V10/*",
        "~/Library/Messages/Attachments/*",
        "~/Library/Containers/com.example.App/Data",
        "~/Library/Group Containers/group.x/Library",
        "~/Library/Application Support/AddressBook/Sources",
        "~/Library/Application Support/MobileSync/Backup",
        "~/Library/Developer/*",
        "~/Library/Photos/Libraries/x",
        "~/.config/app/cache",
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
        "~/.cargo/registry/*",
        "~/Library/pnpm/store/*",
        "~/library/caches/x",
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

    /// Device backups and installer data may be listed for a look, never be part of a clean (F-0027).
    @Test func backupRootsAreForManualRulesOnly() {
        let backups = "~/Library/Application Support/MobileSync/Backup/*"
        #expect(PatternValidator.problem(with: backups, safety: .manual) == nil)
        #expect(PatternValidator.problem(with: backups, safety: .review) != nil)
        #expect(PatternValidator.problem(with: "/System/Volumes/Data/macOS Install Data", safety: .safe) != nil)

        let rule = CleanupRule(id: "backups", title: "", category: .system, safety: .safe, paths: [backups], minimumAgeDays: nil, note: "")
        #expect(CleanupCatalog(version: 1, rules: [rule]).validated().catalog.rules.isEmpty)
    }
}
