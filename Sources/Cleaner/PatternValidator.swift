import Foundation

/// A rule the catalog refused, and why. Rules are dropped whole: one bad pattern is enough.
public struct RuleRejection: Sendable, Hashable {
    public var ruleID: String
    public var pattern: String
    public var reason: String
}

/// Decides whether a catalog pattern may ever be expanded (F-0032). Fails closed: a pattern must lie
/// inside one of the few folders the catalog is for; everything else, including every never-touch
/// area (Keychains, ~/.ssh, Mail, Messages, Containers, the user's documents, iCloud), is refused.
public enum PatternValidator {
    /// Absolute locations outside home that a rule may name. Everything else absolute is refused.
    static let allowedAbsoluteRoots = ["/System/Volumes/Data/macOS Install Data"]

    /// Folders under home a rule may reach into, as lowercased components.
    static let allowedHomeRoots: [[String]] = [
        "Library/Caches", "Library/Logs", "Library/Developer", "Library/pnpm", "Library/Application Support/MobileSync/Backup",
        ".npm", ".gradle", ".m2", ".cargo",
    ].map { $0.lowercased().split(separator: "/").map(String.init) }

    /// Patterns here may only belong to `manual` rules: device backups and installer data are listed, never cleaned.
    static let manualOnlyRoots = ["~/library/application support/mobilesync/backup", "/system/volumes/data/macos install data"]

    /// `~/Library/<folder>/*` is allowed only for these; `~/Library/Developer/*` would take Xcode and every simulator.
    static let libraryFoldersOpenToGlobs: Set = ["caches", "logs"]

    static let globCharacters = CharacterSet(charactersIn: "*?[]")

    /// Why `pattern` is refused, or `nil` when it may be used.
    public static func problem(with pattern: String) -> String? {
        if pattern.hasPrefix("~/") {
            return problem(withHomeComponents: pattern.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).map(String.init))
        }
        if pattern.hasPrefix("/") {
            let insideAllowedRoot = allowedAbsoluteRoots.contains { pattern == $0 || pattern.hasPrefix($0 + "/") }
            guard insideAllowedRoot else { return "absolute path outside the allowed roots" }
            return problem(withComponents: pattern.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init))
        }
        return "must start with ~/ or an allowed absolute root"
    }

    /// Why `pattern` may not be used by a rule of this safety level, or `nil`.
    public static func problem(with pattern: String, safety: SafetyLevel) -> String? {
        if let problem = problem(with: pattern) { return problem }
        let lowercased = pattern.lowercased()
        let manualOnly = manualOnlyRoots.contains { lowercased == $0 || lowercased.hasPrefix($0 + "/") }
        return manualOnly && safety != .manual ? "may only be listed for manual review" : nil
    }

    private static func problem(withHomeComponents components: [String]) -> String? {
        if let problem = problem(withComponents: components) { return problem }
        guard components.count >= 3 else { return "less than three levels below home" }
        let lowercased = components.map { $0.lowercased() }
        guard allowedHomeRoots.contains(where: { lowercased.count > $0.count && lowercased.starts(with: $0) }) else {
            return "outside the folders cleanup rules may use"
        }
        if lowercased[0] == "library" && components.count == 3 && hasGlob(components[2]) && !libraryFoldersOpenToGlobs.contains(lowercased[1]) {
            return "a glob directly inside ~/Library/\(components[1])"
        }
        return nil
    }

    private static func problem(withComponents components: [String]) -> String? {
        for (index, component) in components.enumerated() {
            if component.isEmpty { return "empty path component" }
            if component == "." || component == ".." { return "relative component \(component)" }
            let lowercased = component.lowercased()
            if lowercased.contains("com~apple~") || lowercased.contains("fileprovider") { return "inside a file provider folder" }
            if component.contains("$") || component.contains("~") || component.contains("\\") {
                return "variables, ~ and escapes are not expanded"
            }
            if hasGlob(component) && index != components.count - 1 { return "glob outside the last component" }
        }
        return nil
    }

    static func hasGlob(_ component: String) -> Bool {
        component.rangeOfCharacter(from: globCharacters) != nil
    }
}

extension CleanupCatalog {
    /// This catalog without any rule that has an invalid pattern, and the reasons they were dropped.
    public func validated() -> (catalog: CleanupCatalog, rejections: [RuleRejection]) {
        var rejections: [RuleRejection] = []
        let valid = rules.filter { rule in
            let problems = rule.paths.compactMap { pattern in
                PatternValidator.problem(with: pattern, safety: rule.safety).map { RuleRejection(ruleID: rule.id, pattern: pattern, reason: $0) }
            }
            rejections += problems
            return problems.isEmpty && !rule.paths.isEmpty
        }
        return (CleanupCatalog(version: version, rules: valid), rejections)
    }
}
