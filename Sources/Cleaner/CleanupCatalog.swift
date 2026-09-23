import Foundation
import os

/// How much trust a rule's matches get in the UI (F-0027).
public enum SafetyLevel: String, Codable, Sendable, CaseIterable {
    /// Regenerable data. Preselected.
    case safe
    /// Usually fine, but the user should look first. Shown unselected, with the rule's note.
    case review
    /// Listed with size and Reveal in Finder only; never part of a bulk clean (backups, archives).
    case manual
}

public enum CleanupCategory: String, Codable, Sendable, CaseIterable {
    case appCaches
    case logs
    case developer
    case browsers
    case system
}

public struct CleanupRule: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var category: CleanupCategory
    public var safety: SafetyLevel
    /// Patterns under `~/` or an allowed absolute root. `*` may appear in the last component only.
    public var paths: [String]
    /// Matches newer than this are skipped. `nil` uses the cleaner's in-use guard only.
    public var minimumAgeDays: Int?
    /// Why this is safe (or not), shown to the user.
    public var note: String

    public init(id: String, title: String, category: CleanupCategory, safety: SafetyLevel, paths: [String], minimumAgeDays: Int?, note: String) {
        self.id = id
        self.title = title
        self.category = category
        self.safety = safety
        self.paths = paths
        self.minimumAgeDays = minimumAgeDays
        self.note = note
    }
}

/// The rule set. Loaded only from the signed app bundle, never from a user-writable file (F-0021).
public struct CleanupCatalog: Codable, Sendable {
    public var version: Int
    public var rules: [CleanupRule]

    public init(version: Int, rules: [CleanupRule]) {
        self.version = version
        self.rules = rules
    }

    /// The catalog shipped inside the signed app, with invalid rules dropped and logged (F-0021, F-0032).
    public static func bundled() throws -> CleanupCatalog {
        let (catalog, rejections) = try unvalidatedBundled().validated()
        for rejection in rejections {
            Logger(subsystem: "Macontrol", category: "Cleaner")
                .error("dropped rule \(rejection.ruleID, privacy: .public): \(rejection.pattern, privacy: .public) is \(rejection.reason, privacy: .public)")
        }
        return catalog
    }

    static func unvalidatedBundled() throws -> CleanupCatalog {
        // SwiftPM's Bundle.module only looks beside the executable; in the .app the resource
        // bundle sits in Contents/Resources (scripts/bundle-app.sh), where code signing allows it.
        let resources = Bundle.main.url(forResource: "macontrol_Cleaner", withExtension: "bundle").flatMap(Bundle.init(url:))
            ?? Bundle.module
        guard let url = resources.url(forResource: "catalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(CleanupCatalog.self, from: Data(contentsOf: url))
    }
}
