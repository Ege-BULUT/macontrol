import Cleaner
import Foundation
import MacontrolCore

extension CleanModel {
    /// Sample results covering every row state: safe, review, manual, skipped, unreadable inside.
    /// Paths are fictional and nothing is read or moved.
    static func demo() -> CleanModel {
        CleanModel(cleaner: nil, trash: nil, engine: nil, items: DemoCleanup.items)
    }
}

enum DemoCleanup {
    static let caches = rule("user-app-caches", "App caches", .appCaches, .safe, "Apps rebuild their caches when they need them.")
    static let chrome = rule("chrome-cache", "Chrome cache", .browsers, .safe, "Chrome rebuilds its cache. History, passwords and bookmarks are stored elsewhere.")
    static let safari = rule("safari-cache", "Safari cache", .browsers, .safe, "Safari rebuilds its cache. History and bookmarks are stored elsewhere.")
    static let derived = rule("xcode-derived-data", "Xcode build data", .developer, .safe, "Xcode rebuilds this on the next build, which takes longer once.")
    static let simulators = rule("simulator-devices", "Simulator devices", .developer, .review, "Apps and data inside these simulators are deleted with them.")
    static let archives = rule("xcode-archives", "Xcode archives", .developer, .manual, "Builds you shipped. Keep the ones you need to read crash reports.")
    static let logs = rule("user-logs", "App logs", .logs, .review, "Useful when you report a problem to an app's developer. Otherwise safe to remove.")
    static let backups = rule("device-backups", "iPhone and iPad backups", .system, .manual, "Delete old backups from Finder's device window once a newer one exists.")

    static let items: [CleanupItem] = [
        item(caches, "Library/Caches/com.example.Editor", 1.31),
        item(caches, "Library/Caches/com.spotify.client", 0.84),
        item(caches, "Library/Caches/Homebrew", 2.26),
        item(chrome, "Library/Caches/Google/Chrome", 0.92),
        item(safari, "Library/Caches/com.apple.Safari", 0.41, skip: "Safari is running"),
        item(derived, "Library/Developer/Xcode/DerivedData/Macontrol-abc", 6.8),
        item(derived, "Library/Developer/Xcode/DerivedData/Sketchbook-fgh", 1.2, incomplete: true),
        item(simulators, "Library/Developer/CoreSimulator/Devices/5A1C-iPhone-15", 3.4),
        item(archives, "Library/Developer/Xcode/Archives/2026-08-01", 2.1),
        item(logs, "Library/Logs/Editor", 0.12),
        item(logs, "Library/Logs/DiagnosticReports", 0.03, skip: "Changed in the last 10 minutes"),
        item(backups, "Library/Application Support/MobileSync/Backup/00008110-001A", 18.7),
    ]

    private static func rule(_ id: String, _ title: String, _ category: CleanupCategory, _ safety: SafetyLevel, _ note: String) -> CleanupRule {
        CleanupRule(id: id, title: title, category: category, safety: safety, paths: [], minimumAgeDays: nil, note: note)
    }

    private static func item(_ rule: CleanupRule, _ path: String, _ gigabytes: Double, skip: String? = nil, incomplete: Bool = false) -> CleanupItem {
        let bytes = UInt64(gigabytes * 1_000_000_000)
        return CleanupItem(
            rule: rule, url: URL(fileURLWithPath: "/Users/demo/\(path)"), identity: nil,
            measurement: ItemMeasurement(allocated: bytes, logical: bytes, fileCount: 1200, newestModification: nil, isIncomplete: incomplete),
            skipReason: skip
        )
    }
}
